require File.join([File.dirname(__FILE__), 'switch_variant'])

module MetricTracking
  
  #Metric Tracking routes
  class << ActionController::Routing::Routes;self;end.class_eval do
    define_method :clear!, lambda {}
  end
  
  #TODO: Namespace?
  ActionController::Routing::Routes.draw do |map|
    map.mg '/mg', :controller => :mountain_goat_converts, :action => :index
    map.resources :mountain_goat_metric_variants
    map.resources :mountain_goat_converts, :has_many => :mountain_goat_metrics
    map.resources :mountain_goat_metrics, :has_many => :mountain_goat_metric_variants
    map.resources :mountain_goat_upgrade_orders
    map.fresh_metrics '/fresh-metrics', :controller => :mountain_goat_metrics, :action => :fresh_metrics  
  end
  
  module Controller
  
    ######################
    #   Metric Tracking  #
    ######################
  
    def sv(metric_type, convert_type, &block)
      raise ArgumentError, "Switch variant needs block" if !block_given?
      metric, convert = get_metric_convert( metric_type, convert_type, true )
      block.call(SwitchVariant.new( logger, metric, convert, nil ) )
      
      var = get_switch_metric_variant(metric_type, convert_type)
      block.call(SwitchVariant.new( logger, metric, convert, var ) )
    end
    
    def mv(metric_type, convert_type, default, opts = {}, opt = nil)
      return get_metric_variant(metric_type, convert_type, default, opts, opt)
    end
  
    #shorthand
    def rc(convert_type, options = {})
      self.record_conversion(convert_type, options)
    end
    
    def record_conversion(convert_type, options = {})
      
      #We want some system for easy default parameter setting
      if options.include?(:refs) && options[:refs]
        options = options.merge( :ref_domain => session[:ref_domain], :ref_flyer => session[:ref_flyer], :ref_user => session[:ref_user] )
        options.delete(:refs)
      end
      
      if options.include?(:user) && options[:user]
        options = options.merge( :user_id => current_user.id ) if signed_in?
        options.delete(:user)
      end
      
      if options.include?(:invitees) && options[:invitees]
        invitee_meta = {}
        if session[:invitee_id]
          invitee = Invitee.find_by_id(session[:invitee_id])
          if invitee.mailer.clique == @clique
            options.merge!( { :mailer_id => invitee.mailer.id } )
          end
        end
        options.delete(:invitees)
      end
      
      logger.warn "Recording conversion #{convert_type.to_s} with options #{options.inspect}"
      
      convert = Convert.first( :conditions => { :convert_type => convert_type.to_s } )
      
      #now, we just create the convert if we don't have one
      convert = Convert.create!( :convert_type => convert_type.to_s, :name => convert_type.to_s ) if convert.nil?
      
      #first, let's tally for the conversion itself
      #we need to see what meta information we should fill based on the conversion type
      Rally.create!( { :convert_id => convert.id } ).set_meta_data(options)
      
      if defined?(cookies)
        #we just converted, let's tally each of our metrics (from cookies)
        convert.metrics.each do |metric|
          metric_sym = "metric_#{metric.metric_type}".to_sym
          metric_variant_sym = "metric_#{metric.metric_type}_variant".to_sym
          
          value = cookies[metric_sym]
          variant_id = cookies[metric_variant_sym]
          
          #logger.warn "Value: #{metric_sym} - #{value}"
          #logger.warn "Value: #{metric_variant_sym} - #{variant_id}"
          
          if variant_id.blank? #the user just doesn't have this set
            next
          end
          
          variant = MetricVariant.first(:conditions => { :id => variant_id.to_i } )
          
          if variant.nil?
            logger.error "Variant #{variant_id} not in metric variants for #{metric.title}"
            next
          end
          
          if variant.value != value
            logger.warn "Variant #{variant.name} values differ for metric #{metric.title}.  '#{variant.value}' != '#{value}'!"
          end
          
          logger.warn "Tallying conversion #{convert.name} for #{metric.title} - #{variant.name} (#{variant.value} - #{variant.id})"
          variant.tally_convert
        end
      end
    end
    
    private
    
    def get_metric_variant(metric_type, convert_type, default, opts = {}, opt = nil)
      metric_sym = "metric_#{metric_type}#{ opt.nil? ? "" : '_' + opt.to_s }".to_sym
      metric_variant_sym = "metric_#{metric_type}_variant".to_sym
      
      #first, we'll check for a cookie value
      if defined?(cookies) && cookies[metric_sym] && !cookies[metric_sym].blank?
        #we have the cookie  
        variant_id = cookies[metric_variant_sym]
        variant = MetricVariant.first(:conditions => { :id => variant_id.to_i } )
        if !variant.nil?
          if variant.metric.tally_each_serve
            variant.tally_serve
          end
        else
          logger.warn "Serving metric #{metric_type} #{ opt.nil? ? "" : opt.to_s } without finding / tallying variant."
        end
        
        return cookies[metric_sym] #it's the best we can do
      else
        #we don't have the cookie, let's find a value to set
        metric, convert = get_metric_convert( metric_type, convert_type, false )
        
        #to use RAND(), let's not use metrics.metric_variants
        sum_priority = MetricVariant.first(:select => "SUM(priority) as sum_priority", :conditions => { :metric_id => metric.id } ).sum_priority.to_f
        
        if sum_priority > 0.0
          metric_variant = MetricVariant.first(:order => "RAND() * ( priority / #{sum_priority.to_f} ) DESC", :conditions => { :metric_id => metric.id } )
        end
        
        if metric_variant.nil?
          logger.warn "Missing metric variants for #{metric_type}"
          metric_variant = MetricVariant.create!( { :metric_id => metric.id, :value => default, :name => default }.merge(opts) )
        end
        
        metric_variant.tally_serve #donate we served this to a user
        value = metric_variant.read_attribute( opt.nil? ? :value : opt )
        logger.debug "Serving #{metric_variant.name} (#{value}) for #{metric_sym}"
        #good, we have a variant, let's store it in session
        
        if defined?(cookies)
          cookies[metric_sym] = { :value => value } #, :domain => WILD_DOMAIN
          cookies[metric_variant_sym] = { :value => metric_variant.id } #, :domain => WILD_DOMAIN
        end
        
        return value
      end
    end
    
    def get_switch_metric_variant(metric_type, convert_type)
      metric_variant_sym = "metric_#{metric_type}_variant".to_sym
      
      #first, we'll check for a cookie selection
      if defined?(cookies) && cookies[metric_variant_sym] && !cookies[metric_variant_sym].blank?
        #we have the cookie
        
        variant_id = cookies[metric_variant_sym]
        variant = MetricVariant.first(:conditions => { :id => variant_id.to_i } )
        if !variant.nil?
        
          if variant.metric.tally_each_serve
            variant.tally_serve
          end
          
          return variant
          
        end
        
        #otherwise, it's a big wtf? let's just move on
        logger.warn "Missing metric variant for #{metric_type} (switch-type), reassigning..."
      end
        
      #we don't have the cookie, let's find a value to set
      metric, convert = get_metric_convert( metric_type, convert_type, true )
      
      #to use RAND(), let's not use metrics.metric_variants
      sum_priority = MetricVariant.first(:select => "SUM(priority) as sum_priority", :conditions => { :metric_id => metric.id } ).sum_priority.to_f
      
      if sum_priority > 0.0
        metric_variant = MetricVariant.first(:order => "RAND() * ( priority / #{sum_priority.to_f} ) DESC", :conditions => { :metric_id => metric.id } )
      end
      
      if metric_variant.nil?
        logger.warn "Missing metric variants for #{metric_type}"
        raise ArgumentError, "Missing variants for switch-type #{metric_type}"
      end
      
      metric_variant.tally_serve #donate we served this to a user
      logger.debug "Serving #{metric_variant.name} (#{metric_variant.switch_type}) for #{metric.title} (switch-type)"
      #good, we have a variant, let's store it in session (not the value, just the selection)
      if defined?(cookies)
        cookies[metric_variant_sym] = { :value => metric_variant.id } #, :domain => WILD_DOMAIN
      end
      
      return metric_variant
    end
    
    def get_metric_convert(metric_type, convert_type, is_switch = false)
      
      metric = Metric.first(:conditions => { :metric_type => metric_type.to_s } )
      
      conv = Convert.find_by_convert_type( convert_type.to_s )
      if conv.nil?
        logger.warn "Missing convert type #{convert_type.to_s} -- creating"  
        conv = Convert.create( :convert_type => convert_type.to_s, :name => convert_type.to_s ) if conv.nil?
      end
        
      if metric.nil? #we don't have a metric of this type
        logger.warn "Missing metric type #{metric_type.to_s} -- creating"
        metric = Metric.create( :metric_type => metric_type.to_s, :title => metric_type.to_s, :convert_id => conv.id, :is_switch => is_switch )
      end
      
      return metric, conv
    end
  end
  
  module View
    def mv(*args, &block)
      @controller.send(:mv, *args, &block)
    end
    
    def sv(*args, &block)
      @controller.send(:sv, *args, &block)
    end
  end
end

class ActionController::Base
  include MetricTracking::Controller
end

class ActionView::Base
  include MetricTracking::View
end

class ActionMailer::Base
  include MetricTracking::Controller  
end
