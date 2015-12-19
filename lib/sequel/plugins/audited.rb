# 
class AuditLog < Sequel::Model
  # handle versioning of audited records
  plugin :list, field: :version, scope: [:model_type, :model_pk]
  plugin :timestamps
  
  # TODO: see if we should add these
  # many_to_one :associated, polymorphic: true
  # many_to_one :user,       polymorphic: true
  
  def before_validation
    # grab the current user
    u = get_audit_user
    self.user_id    = u.id
    self.username   = u.username
    self.user_type  = u.class.name
  end
  
  # private
  
  # Obtains the `current_user` based upon the `:audited_current_user_method' value set in the
  # audited model, either via defaults or via :user_method config options
  # 
  # # NOTE! this allows overriding the default value on a per audited model
  def get_audit_user
    m = Kernel.const_get(self.model_type)
    u = send(m.audited_current_user_method)
  end
  
end



module Sequel
  
  #
  module Plugins
    
    # Given a Post model with these fields: 
    #   [:id, :category_id, :title, :body, :author_id, :created_at, :updated_at]
    #
    #
    # All fields
    #   plugin :audited 
    #     #=> [:category_id, :title, :body, :author_id]  # NB! excluding @default_ignore_attrs
    #     #=> [:id, :created_at, :updated_at]
    #
    # Single field
    #   plugin :audited, only: :title
    #   plugin :audited, only: [:title]
    #     #=> [:title]
    #     #+> [:id, :category_id, :body, :author_id, :created_at, :updated_at] # ignored fields
    # 
    # Multiple fields
    #   plugin :audited, only: [:title, :body]
    #     #=> [:title, :body] # tracked fields
    #     #=> [:id, :category_id, :author_id, :created_at, :updated_at] # ignored fields
    # 
    # 
    # All fields except certain fields
    #   plugin :audited, except: :title
    #   plugin :audited, except: [:title]
    #     #=> [:id, :category_id, :author_id, :created_at, :updated_at] # tracked fields
    #     #=> [:title] # ignored fields
    # 
    # 
    # 
    module Audited
            
      # called when 
      def self.configure(model, opts = {})
        model.instance_eval do
          # add support for :dirty attributes tracking & JSON serializing of data
          plugin(:dirty)
          plugin(:json_serializer)
          
          attr_accessor :audited_default_ignored_attrs, :current_user_method
          # by default ignore these attributes
          ignored_vars = [
            # :id, :ref, :password, :password_hash, 
            :lock_version, 
            :created_at, :updated_at, :created_on, :updated_on
          ]
          @audited_default_ignored_attrs = opts[:default_ignored_attrs] ||= ignored_vars
          # sets the name of User method
          @audited_current_user_method = opts[:user_method] ||= :current_user
          
          only    = opts.fetch(:only, [])
          except  = opts.fetch(:except, [])
          
          unless only.empty?
            # we should only track the provided column
            included_columns = [only].flatten
            # subtract the 'only' columns from all columns to get excluded_columns
            excluded_columns = columns - included_columns
          else # except:
            # all columns minus excepted columns and default ignored columns
            included_columns = [[columns - [except].flatten].flatten - @audited_default_ignored_attrs].flatten.uniq
            
            excluded_columns = except.empty? ? [] : [except].flatten
            excluded_columns = [columns - included_columns].flatten.uniq
          end
          
          # puts "\nwhen opts=[#{opts.inspect}]"
          # puts "-- included_columns=[#{included_columns.inspect}]"
          # puts "-- excluded_columns=[#{excluded_columns.inspect}]"
          # puts "end\n"
          @audited_included_columns = included_columns
          @audited_ignored_columns  = excluded_columns
          
          # each included model will have an associated versions
          one_to_many(:versions, 
                      class: ::Sequel::Audited.audited_model_name, 
                      key: :model_pk, 
                      conditions: { model_type: model.name.to_s }
                     )
          
        end
        
      end
      
      # 
      module ClassMethods
        #
        attr_accessor :audited_current_user_method
        # # The column holding the version number in the table
        # attr_accessor :version_field
        # The holder of columns that should be audited
        attr_accessor :audited_columns
        # The holder of ignored columns
        attr_accessor :audited_ignored_columns
        attr_accessor :audited_included_columns
        
        
        Plugins.inherited_instance_variables(self, 
                                             :@audited_default_ignored_attrs => nil,
                                             :@audited_current_user_method   => nil,
                                             :@audited_included_columns      => nil, 
                                             :@audited_ignored_columns       => nil
                                            )
        
        def non_audited_columns
          columns - audited_columns
        end
        
        def audited_columns
          @audited_columns ||= columns - @audited_ignored_columns
        end
        
        def default_ignored_attrs
          @audited_default_ignored_attrs
        end
        
        
        # def default_ignored_attrs
        #   # TODO: how to reference the models primary_key value??
        #   arr = [pk.to_s]
        #   # handle STI (Class Table Inheritance) models with `plugin :single_table_inheritance`
        #   arr << 'sti_key' if self.respond_to?(:sti_key)
        #   arr
        # end
        
        # 
        # returns true / false if any audits have been made
        # 
        #   Post.audited_versions?   #=> true / false
        # 
        def audited_versions?
          # ::AuditLog.where(model_type: name.to_s).count >= 1
          const_get(::Sequel::Audited.audited_model_name)
            .where(model_type: name.to_s).count >= 1
        end
        
        # grab all audits for a particular model based upon filters
        #   
        #   Posts.audited_versions(:model_pk => 123)
        #     #=> filtered by primary_key value
        #    
        #   Posts.audited_versions(:user_id => 88)
        #     #=> filtered by user name
        #     
        #   Posts.audited_versions(:created_at < Date.today - 2)
        #     #=> filtered to last two (2) days only
        #     
        #   Posts.audited_versions(:created_at > Date.today - 7)
        #     #=> filtered to older than last seven (7) days
        #     
        def audited_versions(opts = {})
          # ::AuditLog.where(opts.merge(model_type: name.to_s)).order(:version).all
          const_get(::Sequel::Audited.audited_model_name)
            .where(opts.merge(model_type: name.to_s)).order(:version).all
        end
        
      end
      
      
      # 
      module InstanceMethods
        
        # Returns who put the post into its current state.
        #   
        #   post.blame  
        #   
        #   post.audited_by  => self.versions.last
        def blame
          versions.last.username || 'unknown'
        end
        alias_method :audited_by, :blame
        
        
        private
        
        # extract audited values only
        def extract_audited_values
        end
        
        def after_create
          super
          # changed =  self.values || 'null'
          changed = column_changes.empty? ? previous_changes : column_changes
          # :user, :version & :created_at set in model
          add_version(
            model_type: model,
            model_pk:   pk,
            event:      'create',
            changed:    changed.to_json
          )
        end
        
        def after_update
          super
          changed = column_changes.empty? ? previous_changes : column_changes
          # :user, :version & :created_at set in model
          add_version(
            model_type:  model,
            model_pk:    pk,
            event:       'update',
            changed:     changed.to_json
          )
        end
        
        def after_destroy
          super
          # :user, :version & :created_at set in model
          add_version(
            model_type:  model,
            model_pk:    pk,
            event:       'destroy',
            changed:     self.to_json
          )
        end
        
      end
      
    end
    
  end
  
end
