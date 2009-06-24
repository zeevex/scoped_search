module ScopedSearch
  class Builder
    attr_accessor :model

    def initialize(model, fields = [])
      self.model = model

      @name = :search_for
      @fields = fields
    end

    def [](name)
      self.instance_variable_get("@#{name}")
    end
    
    def name(val); @name = val; end
    def fields(*val); @fields = val.flatten; end
  end

  class FieldSpec
    attr_accessor :model, :scoped_search_fields, :scoped_search_assoc_groupings

    def initialize(model, fields)
      self.model = model
      parse_fields(Array(fields).flatten.map &:to_sym)
    end

    def parse_fields(fields)
      # Make sure that the table to be searched actually exists
      if model.table_exists?

        # Get a collection of fields to be searched on.
        if fields.first.class.to_s == 'Hash'
          if fields.first.has_key?(:only)
            # only search on these fields.
            fields = fields.first[:only]
          elsif fields.first.has_key?(:except)
            # Get all the fields and remove any that are in the -except- list.
            fields = model.column_names.collect { |column| fields.first[:except].include?(column.to_sym) ? nil : column.to_sym }.compact
          end
        end

        # Get an array of associate modules.
        assoc_models = model.reflections.collect { |key,value| key }

        # Subtract out the fields to be searched on that are part of *this* model.
        # Any thing left will be associate module fields to be searched on.
        assoc_fields = fields - model.column_names.collect { |column| column.to_sym }

        # Subtraced out the associated fields from the fields so that you are only left
        # with fields in *this* model.
        fields -= assoc_fields

        # Loop through each of the associate models and group accordingly each
        # associate model field to search.  Assuming the following relations:
        # has_many :clients
        # has_many :notes,
        # belongs_to :user_type
        # assoc_groupings will look like
        # assoc_groupings = {:clients => [:first_name, :last_name],
        #                    :notes => [:descr],
        #                    :user_type => [:identifier]}
        assoc_groupings = {}
        assoc_models.each do |assoc_model|
          assoc_groupings[assoc_model] = []
        	assoc_fields.each do |assoc_field|
        	  unless assoc_field.to_s.match(/^#{assoc_model.to_s}_/).nil?
              assoc_groupings[assoc_model] << assoc_field.to_s.sub(/^#{assoc_model.to_s}_/, '').to_sym
            end
          end
        end

        # If a grouping does not contain any fields to be searched on then remove it.
        assoc_groupings = assoc_groupings.delete_if {|group, field_group| field_group.empty?}

        # Set the appropriate class attributes.
        self.scoped_search_fields = fields
        self.scoped_search_assoc_groupings = assoc_groupings
      end
    end

    # Build a hash that is used for the named_scope search_for.
    # This function will split the search_string into keywords, and search for all the keywords
    # in the fields that were provided to searchable_on.
    #
    # search_string:: The search string to parse.
    def build_scoped_search_conditions(search_string)
      if search_string.nil? || search_string.strip.blank?
        return {:conditions => nil}
      else
        query_fields = {}
        self.scoped_search_fields.each do |field|
          field_name = model.connection.quote_table_name(model.table_name) + "." + model.connection.quote_column_name(field)
          query_fields[field_name] = model.columns_hash[field.to_s].type
        end

        assoc_model_indx = 0
        assoc_fields_indx = 1
        assoc_models_to_include = []
        self.scoped_search_assoc_groupings.each do |group|
          assoc_models_to_include << group[assoc_model_indx]
          group[assoc_fields_indx].each do |group_field|
            field_name = model.connection.quote_table_name(group[assoc_model_indx].to_s.pluralize) + "." + model.connection.quote_column_name(group_field)
            query_fields[field_name] = model.reflections[group[assoc_model_indx]].klass.columns_hash[group_field.to_s].type
          end
        end

        search_conditions = ScopedSearch::QueryLanguageParser.parse(search_string)
        conditions = ScopedSearch::QueryConditionsBuilder.build_query(search_conditions, query_fields)

        retval = {:conditions => conditions}
        retval[:include] = assoc_models_to_include unless assoc_models_to_include.empty?

        return retval
      end
    end
  end

  module ClassMethods
    
    def self.extended(base) # :nodoc:
      require 'scoped_search/reg_tokens'
      require 'scoped_search/query_language_parser'
      require 'scoped_search/query_conditions_builder'
    end

    def acts_as_scoped_search(name = :scoped_search, *fields)
      fields.size == 0 && fields = self.columns_hash.keys
      model = self
      built_spec = ScopedSearch::FieldSpec.new(model, fields)
      self.named_scope name, lambda { |*args|
        keywords = args.shift
        spec_to_use = args.size == 0 ? built_spec : ScopedSearch::FieldSpec.new(model, args.flatten)
        spec_to_use.build_scoped_search_conditions(keywords)
      }
    end
 
    def searchable_on(*fields, &block)
      fields.size == 0 && fields = self.columns_hash.keys
      builder = Builder.new(self, fields)
      builder.instance_eval(&block)
      self.acts_as_scoped_search(builder['name'], builder['fields'])
    end
    
  end
end

ActiveRecord::Base.send(:extend, ScopedSearch::ClassMethods)
