module ActsAsParanoid
  module Core
    def self.included(base)
      base.extend ClassMethods
    end

    module ClassMethods
      def self.extended(base)
        base.define_callbacks :recover
      end

      def before_recover(method)
        set_callback :recover, :before, method
      end

      def after_recover(method)
        set_callback :recover, :after, method
      end

      def with_deleted
        without_paranoid_default_scope
      end

      def only_deleted
        if string_type_with_deleted_value?
          without_paranoid_default_scope.where("#{paranoid_column_reference} IS ?", paranoid_configuration[:deleted_value])
        elsif boolean_type_not_nullable?
          without_paranoid_default_scope.where("#{paranoid_column_reference} = ?", true)
        else
          without_paranoid_default_scope.where("#{paranoid_column_reference} IS NOT ?", nil)
        end
      end

      def delete_all!(conditions = nil)
        without_paranoid_default_scope.delete_all!(conditions)
      end

      def delete_all(conditions = nil)
        where(conditions).update_all(["#{paranoid_configuration[:column]} = ?", delete_now_value])
      end

      def paranoid_default_scope_sql
        if string_type_with_deleted_value?
          self.all.table[paranoid_column].eq(nil).
            or(self.all.table[paranoid_column].not_eq(paranoid_configuration[:deleted_value])).
            to_sql
        elsif boolean_type_not_nullable?
          self.all.table[paranoid_column].eq(false).to_sql
        else
          self.all.table[paranoid_column].eq(nil).to_sql
        end
      end

      def string_type_with_deleted_value?
        paranoid_column_type == :string && !paranoid_configuration[:deleted_value].nil?
      end

      def boolean_type_not_nullable?
        paranoid_column_type == :boolean && !paranoid_configuration[:allow_nulls]
      end

      def paranoid_column
        paranoid_configuration[:column].to_sym
      end

      def paranoid_column_type
        paranoid_configuration[:column_type].to_sym
      end

      def dependent_associations
        self.reflect_on_all_associations.select {|a| [:destroy, :delete_all].include?(a.options[:dependent]) }
      end

      def delete_now_value
        case paranoid_configuration[:column_type]
        when "time" then Time.now
        when "boolean" then true
        when "string" then paranoid_configuration[:deleted_value]
        end
      end

    protected

      def without_paranoid_default_scope
        scope = self.all
        if scope.where_values.include? paranoid_default_scope_sql
          # ActiveRecord 4.1
          scope.where_values.delete(paranoid_default_scope_sql)
        else
          scope = scope.with_default_scope
          scope.where_values.delete(paranoid_default_scope_sql)
        end

        scope
      end
    end

    def persisted?
      !(new_record? || @destroyed)
    end

    def paranoid_value
      self.send(self.class.paranoid_column)
    end

    def destroy_fully!
      with_transaction_returning_status do
        run_callbacks :destroy do
          destroy_dependent_associations!
          # Handle composite keys, otherwise we would just use `self.class.primary_key.to_sym => self.id`.
           if persisted?
            affected_rows = self.class.delete_all!(Hash[[Array(self.class.primary_key), Array(self.id)].transpose])
            if ActiveRecord::VERSION::MAJOR >= 4 && ActiveRecord::VERSION::MINOR >= 2
              association_decrement_counters affected_rows
            end
          end
          self.paranoid_value = self.class.delete_now_value
          freeze
        end
      end
    end

    def destroy!
      if !deleted?
        with_transaction_returning_status do
          run_callbacks :destroy do
            # Handle composite keys, otherwise we would just use `self.class.primary_key.to_sym => self.id`.
            if persisted?
              affected_rows = self.class.delete_all(Hash[[Array(self.class.primary_key), Array(self.id)].transpose])
              if ActiveRecord::VERSION::MAJOR >= 4 && ActiveRecord::VERSION::MINOR >= 2
                association_decrement_counters affected_rows
              end
            end
            self.paranoid_value = self.class.delete_now_value
            self
          end
        end
      else
        destroy_fully!
      end
    end

    def destroy
      destroy!
    end

    def recover(options={})
      options = {
        :recursive => self.class.paranoid_configuration[:recover_dependent_associations],
        :recovery_window => self.class.paranoid_configuration[:dependent_recovery_window]
      }.merge(options)

      self.class.transaction do
        run_callbacks :recover do
          recover_dependent_associations(options[:recovery_window], options) if options[:recursive]

          self.paranoid_value = nil
          self.save
        end
      end
    end

    def recover_dependent_associations(window, options)
      self.class.dependent_associations.each do |reflection|
        next unless (klass = get_reflection_class(reflection)).paranoid?

        scope = klass.only_deleted

        # Merge in the association's scope
        scope = scope.merge(association(reflection.name).association_scope)

        # We can only recover by window if both parent and dependant have a
        # paranoid column type of :time.
        if self.class.paranoid_column_type == :time && klass.paranoid_column_type == :time
          scope = scope.deleted_inside_time_window(paranoid_value, window)
        end

        scope.each do |object|
          object.recover(options)
        end
      end
    end

    def destroy_dependent_associations!
      self.class.dependent_associations.each do |reflection|
        next unless (klass = get_reflection_class(reflection)).paranoid?

        scope = klass.only_deleted

        # Merge in the association's scope
        scope = scope.merge(association(reflection.name).association_scope)

        scope.each do |object|
          object.destroy!
        end
      end
    end

    def deleted?
      !if self.class.string_type_with_deleted_value?
        paranoid_value != self.class.delete_now_value || paranoid_value.nil?
      elsif self.class.boolean_type_not_nullable?
        paranoid_value == false
      else
        paranoid_value.nil?
      end
    end

    alias_method :destroyed?, :deleted?

    private

    def get_reflection_class(reflection)
      if reflection.macro == :belongs_to && reflection.options.include?(:polymorphic)
        self.send(reflection.foreign_type).constantize
      else
        reflection.klass
      end
    end

    def paranoid_value=(value)
      self.send("#{self.class.paranoid_column}=", value)
    end

    def association_decrement_counters(affected_rows)
      if affected_rows > 0
        each_counter_cached_associations do |association|
          foreign_key = association.reflection.foreign_key.to_sym
          unless destroyed_by_association && destroyed_by_association.foreign_key.to_sym == foreign_key
            if send(association.reflection.name)
              association.send(:decrement_counters)
            end
          end
        end
      end
    end

    def each_counter_cached_associations
      _reflections.each do |name, reflection|
        yield association(name.to_sym) if reflection.belongs_to? && reflection.counter_cache_column
      end
    end
  end
end
