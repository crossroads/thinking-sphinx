module ThinkingSphinx
  # Association tracks a specific reflection and join to reference data that
  # isn't in the base model. Very much an internal class for Thinking Sphinx -
  # perhaps because I feel it's not as strong (or simple) as most of the rest.
  #
  class Association
    attr_accessor :parent, :reflection, :join, :columns

    # Create a new association by passing in the parent association, and the
    # corresponding reflection instance. If there is no parent, pass in nil.
    #
    #   top   = Association.new nil, top_reflection
    #   child = Association.new top, child_reflection
    #
    def initialize(parent, reflection)
      @parent, @reflection = parent, reflection
      @columns = []
      @children = {}
    end

    # Get the children associations for a given association name. The only time
    # that there'll actually be more than one association is when the
    # relationship is polymorphic. To keep things simple though, it will always
    # be an Array that gets returned (an empty one if no matches).
    #
    #   # where pages is an association on the class tied to the reflection.
    #   association.children(:pages)
    #
    def children(assoc)
      @children[assoc] ||= Association.children(@reflection.klass, assoc, self)
    end

    # Get the children associations for a given class, association name and
    # parent association. Much like the instance method of the same name, it
    # will return an empty array if no associations have the name, and only
    # have multiple association instances if the underlying relationship is
    # polymorphic.
    #
    #   Association.children(User, :pages, user_association)
    #
    def self.children(klass, assoc, parent=nil)
      ref = klass.reflect_on_association(assoc)

      return [] if ref.nil?
      return [Association.new(parent, ref)] unless ref.options[:polymorphic]

      # association is polymorphic - create associations for each
      # non-polymorphic reflection.
      polymorphic_classes(ref).collect { |poly_class|
        Association.new parent, depolymorphic_reflection(ref, klass, poly_class)
      }
    end

    # Link up the join for this model from a base join - and set parent
    # associations' joins recursively.
    #
    def join_to(base_join)
      parent.join_to(base_join) if parent && parent.join.nil?

      @join ||= ::ActiveRecord::Associations::ClassMethods::JoinDependency::JoinAssociation.new(
        @reflection, base_join, parent ? parent.join : base_join.joins.first
      )

      @join.aliased_table_name << '_join' if is_many? and !(@join.aliased_table_name =~ /_join$/)
    end

    def column_def_sql(column_name)
      if column_name.to_s =~ /_id$/
        "#{quote_column(column_name)} int(11) NOT NULL"
      elsif column_name.to_s =~ /_ids$/
        "#{quote_column(column_name)} BLOB default NULL"
      else
        "#{quote_column(column_name)} TEXT default NULL"
      end
    end

    # Returns the association's flattened columns as an indexed tempory table
    # to speed up the joins and avoid a huge group by statement
    #
    def to_flat_sql
      primary_key = quote_column(@reflection.primary_key_name)
      temp_table_name = quote_table_name(@join.aliased_table_name)

      create = "CREATE TEMPORARY TABLE %s (%s, PRIMARY KEY (%s))" % [
        temp_table_name,
        (columns.uniq.map(&:__name) << @reflection.primary_key_name).map { |column| column_def_sql(column) }.join(', '),
        primary_key
      ]

      insert = "INSERT INTO %s (%s)" % [
        temp_table_name,
        (columns.uniq.map { |column| quote_column(column.__name) } << primary_key).join(', ')
      ]

      insert << " SELECT %s FROM %s" % [
        (columns.uniq.map { |column| column_sql(column.__name) } << primary_key).join(', '),
        @reflection.quoted_table_name
      ]

      insert << " INNER JOIN %s ON %s.%s = %s.%s" % [
        quote_table_name(@reflection.options[:join_table]),
        quote_table_name(@reflection.options[:join_table]),
        quote_column(@reflection.association_foreign_key),
        @reflection.quoted_table_name,
        quote_column(@join.primary_key)
      ] if @reflection.macro == :has_and_belongs_to_many

      insert << " GROUP BY %s" % [
        primary_key
      ]

      [create, insert]
    end

    # Returns the association's join SQL statements - and it replaces
    # ::ts_join_alias:: with the aliased table name so the generated reflection
    # join conditions avoid column name collisions.
    #
    def to_sql
      rewrite_conditions
    end

    # Returns true if the association - or a parent - is a has_many or
    # has_and_belongs_to_many.
    #
    def is_many?
      case @reflection.macro
      when :has_many, :has_and_belongs_to_many
        true
      else
        @parent ? @parent.is_many? : false
      end
    end

    def adapter
      @adapter ||= @reflection.klass.sphinx_database_adapter
    end

    def column_sql(column)
       separator = column == :id ? ',' : ' '
      "#{adapter.group_concatenate(column, separator)} AS #{quote_column(column)}"
    end

    def quote_column(column)
      @reflection.klass.connection.quote_column_name(column)
    end

    def quote_table_name(table_name)
      @reflection.klass.connection.quote_table_name(table_name)
    end

    # Returns an array of all the associations that lead to this one - starting
    # with the top level all the way to the current association object.
    #
    def ancestors
      (parent ? parent.ancestors : []) << self
    end

    def has_column?(column)
      @reflection.klass.column_names.include?(column.to_s)
    end

    def primary_key_from_reflection
      if @reflection.options[:through]
        @reflection.source_reflection.options[:foreign_key] ||
        @reflection.source_reflection.primary_key_name
      elsif @reflection.macro == :has_and_belongs_to_many
        @reflection.association_foreign_key
      else
        nil
      end
    end

    def table
      if @reflection.options[:through] ||
        @reflection.macro == :has_and_belongs_to_many
        @join.aliased_join_table_name
      else
        @join.aliased_table_name
      end
    end

    private

    def self.depolymorphic_reflection(reflection, source_class, poly_class)
      name = "#{reflection.name}_#{poly_class.name}".to_sym

      source_class.reflect_on_association(name) ||
      ::ActiveRecord::Reflection::AssociationReflection.new(
        reflection.macro, name, casted_options(poly_class, reflection),
        reflection.active_record
      )
    end

    # Returns all the objects that could be currently instantiated from a
    # polymorphic association. This is pretty damn fast if there's an index on
    # the foreign type column - but if there isn't, it can take a while if you
    # have a lot of data.
    #
    def self.polymorphic_classes(ref)
      ref.active_record.connection.select_all(
        "SELECT DISTINCT #{ref.options[:foreign_type]} " +
        "FROM #{ref.active_record.table_name} " +
        "WHERE #{ref.options[:foreign_type]} IS NOT NULL"
      ).collect { |row|
        row[ref.options[:foreign_type]].constantize
      }
    end

    # Returns a new set of options for an association that mimics an existing
    # polymorphic relationship for a specific class. It adds a condition to
    # filter by the appropriate object.
    #
    def self.casted_options(klass, ref)
      options = ref.options.clone
      options[:polymorphic]   = nil
      options[:class_name]    = klass.name
      options[:foreign_key] ||= "#{ref.name}_id"

      quoted_foreign_type = klass.connection.quote_column_name ref.options[:foreign_type]
      case options[:conditions]
      when nil
        options[:conditions] = "::ts_join_alias::.#{quoted_foreign_type} = '#{klass.name}'"
      when Array
        options[:conditions] << "::ts_join_alias::.#{quoted_foreign_type} = '#{klass.name}'"
      when Hash
        options[:conditions].merge!(ref.options[:foreign_type] => klass.name)
      else
        options[:conditions] << " AND ::ts_join_alias::.#{quoted_foreign_type} = '#{klass.name}'"
      end

      options
    end

    def rewrite_conditions
      if is_many?
        temp_table_name = quote_table_name(@join.aliased_table_name)
        " LEFT OUTER JOIN %s ON %s.%s = %s.%s" % [
          temp_table_name,
          temp_table_name,
          quote_column(@reflection.primary_key_name),
          quote_table_name(@join.parent.aliased_table_name),
          quote_column(@join.parent.primary_key)
        ]
      else
        rewrite_condition @join.association_join
      end
    end

    def rewrite_condition(condition)
      return condition unless condition.is_a?(String)

      if defined?(ActsAsTaggableOn) &&
        @reflection.klass == ActsAsTaggableOn::Tagging &&
        @reflection.name.to_s[/_taggings$/]
        condition = condition.gsub /taggings\./, "#{quoted_alias @join}."
      end

      condition.gsub /::ts_join_alias::/, quoted_alias(@join.parent)
    end

    def quoted_alias(join)
      @reflection.klass.connection.quote_table_name(
        join.aliased_table_name
      )
    end
  end
end
