require 'foreman/controller/auto_complete_search'

class ApplicationController < ActionController::Base
  include Foreman::ThreadSession::Cleaner

  protect_from_forgery # See ActionController::RequestForgeryProtection for details
  rescue_from ScopedSearch::QueryNotSupported, :with => :invalid_search_query
  rescue_from Exception, :with => :generic_exception if Rails.env.production?
  rescue_from ActiveRecord::RecordNotFound, :with => :not_found

  # standard layout to all controllers
  helper 'layout'

  before_filter :set_gettext_locale
  before_filter :require_ssl, :require_login
  before_filter :session_expiry, :update_activity_time, :unless => proc {|c| c.remote_user_provided? || c.api_request? } if SETTINGS[:login]
  before_filter :set_taxonomy, :require_mail, :check_empty_taxonomy
  before_filter :welcome, :only => :index, :unless => :api_request?
  before_filter :authorize


  cache_sweeper :topbar_sweeper, :unless => :api_request?

  def welcome
    @searchbar = true
    klass = controller_name == "dashboard" ? "Host" : controller_name.camelize.singularize
    if (klass.constantize.first.nil? rescue false)
      @searchbar = false
      render :welcome rescue nil and return
    end
  rescue
    not_found
  end

  def api_request?
    request.format.json? or request.format.yaml?
  end

  protected

  # Authorize the user for the requested action
  def authorize(ctrl = params[:controller], action = params[:action])
    allowed = User.current.allowed_to?({:controller => ctrl.gsub(/::/, "_").underscore, :action => action})
    allowed ? true : deny_access
  end

  def deny_access
    (User.current.logged? || request.xhr?) ? render_403 : require_login
  end

  def require_ssl
    # if SSL is not configured, don't bother forcing it.
    return true unless SETTINGS[:require_ssl]
    # don't force SSL on localhost
    return true if request.host=~/localhost|127.0.0.1/
    # finally - redirect
    redirect_to :protocol => 'https' and return if request.protocol != 'https' and not request.ssl?
  end

  def available_sso
    @available_sso ||= SSO.get_available(self)
  end

  # Force a user to login if authentication is enabled
  # Sets User.current to the logged in user, or to admin if logins are not used
  def require_login
    unless session[:user] and (User.current = User.unscoped.find(session[:user]))
      # User is not found or first login
      if SETTINGS[:login]
        # authentication is enabled

        if available_sso.present?
          if available_sso.authenticated?
            user = User.unscoped.find_by_login(available_sso.user)
            User.logout_path = available_sso.logout_path if available_sso.support_logout?
          elsif available_sso.support_login?
            available_sso.authenticate!
            return
          else
            logger.warn("SSO failed, falling back to login form")
          end
        # Else, fall back to the standard authentication mechanism,
        # only if it's an API request.
        elsif api_request?
          user = authenticate_or_request_with_http_basic { |u, p| User.try_to_login(u, p) }
          logger.warn("Failed Basic Auth authentication request from #{request.remote_ip}") unless user
        end

        if user.is_a?(User)
          logger.info("Authorized user #{user.login}(#{user.to_label})")
          User.current = user
          session[:user] = User.current.id unless api_request?
          return !User.current.nil?
        end

        unless api_request?
          session[:original_uri] = request.fullpath # keep the old request uri that we can redirect later on
          redirect_to login_users_path and return
        end
      else
        # We assume we always have a user logged in, if authentication is disabled, the user is the build-in admin account.
        User.current = User.admin
        session[:user] = User.current.id unless api_request?
      end
    end
  end

  def require_mail
    if User.current && User.current.mail.blank?
      notice _("Mail is Required")
      redirect_to edit_user_path(:id => User.current)
    end
  end

  # this method is returns the active user which gets used to populate the audits table
  def current_user
    User.current
  end

  def invalid_request
    render :text => _('Invalid query'), :status => 400
  end

  def not_found(exception = nil)
    logger.debug "not found: #{exception}" if exception
    respond_to do |format|
      format.html { render "common/404", :status => 404 }
      format.json { head :status => 404}
      format.yaml { head :status => 404}
      format.yml { head :status => 404}
    end
    true
  end

  # this method sets the Current user to be the Admin
  # its required for actions which are not authenticated by default
  # such as unattended notifications coming from an OS, or fact and reports creations
  def set_admin_user
    User.current = User.admin
  end

  # searches for an object based on its name and assign it to an instance variable
  # required for models which implement the to_param method
  #
  # example:
  # @host = Host.find_by_name params[:id]
  def find_by_name
    not_found and return if (id = params[:id]).blank?

    obj = controller_name.singularize
    # determine if we are searching for a numerical id or plain name
    cond = "find_by_" + ((id =~ /^\d+$/ && (id=id.to_i)) ? "id" : "name")
    not_found and return unless eval("@#{obj} = #{obj.camelize}.#{cond}(id)")
  end

  def notice notice
    flash[:notice] = notice
  end

  def error error
    flash[:error] = error
  end

  def warning warning
    flash[:warning] = warning
  end

  # this method is used with nested resources, where obj_id is passed into the parameters hash.
  # it automatically updates the search text box with the relevant relationship
  # e.g. /hosts/fqdn/reports # would add host = fqdn to the search bar
  def setup_search_options
    params[:search] ||= ""
    params.keys.each do |param|
      if param =~ /(\w+)_id$/
        unless params[param].blank?
          query = "#{$1} = #{params[param]}"
          params[:search] += query unless params[:search].include? query
        end
      end
    end
  end

  def session_expiry
    if session[:expires_at].blank? or (session[:expires_at].utc - Time.now.utc).to_i < 0
      expire_session
      session[:original_uri] = request.fullpath # keep the old request uri that we can redirect later on
    end
  rescue => e
    logger.warn "failed to determine if user sessions needs to be expired, expiring anyway: #{e}"
    expire_session
  end

  def update_activity_time
    session[:expires_at] = Setting[:idle_timeout].minutes.from_now.utc
  end

  def expire_session
    logger.info "Session for #{current_user} is expired."
    reset_session
    flash[:warning] = _("Your session has expired, please login again")
    redirect_to login_users_path
  end

  def ajax?
    request.xhr?
  end

  def ajax_request
    return head(:method_not_allowed) unless ajax?
  end

  def remote_user_provided?
    return false unless Setting["authorize_login_delegation"]
    return false if api_request? and not Setting["authorize_login_delegation_api"]
    (@remote_user = request.env["REMOTE_USER"]).present?
  end

  private
  def detect_notices
    @notices = current_user.notices
  end

  def require_admin
    unless User.current.admin?
      render_403
      return false
    end
    true
  end

  def render_403
    respond_to do |format|
      format.html { render :template => "common/403", :layout => !request.xhr?, :status => 403 }
      format.atom { head 403 }
      format.yaml { head 403 }
      format.yml  { head 403 }
      format.xml  { head 403 }
      format.json { head 403 }
    end
    false
  end

  def process_success hash = {}
    hash[:object]                 ||= eval("@#{controller_name.singularize}")
    hash[:object_name]            ||= hash[:object].to_s
    hash[:success_msg]            ||= "Successfully #{action_name.pluralize.sub(/es$/,"ed").sub(/ys$/, "yed")} #{hash[:object_name]}."
    hash[:success_redirect]       ||= eval("#{controller_name}_url")
    hash[:json_code]                = :created if action_name == "create"

    return render :json => {:redirect => hash[:success_redirect]} if hash[:redirect_xhr]

    respond_to do |format|
        format.html do
          notice hash[:success_msg]
          redirect_to hash[:success_redirect] and return
        end
        format.json { render :json => hash[:object], :status => hash[:json_code]}
    end
  end

  def process_error hash = {}
    hash[:object] ||= eval("@#{controller_name.singularize}")

    case action_name
    when "create" then hash[:render] ||= "new"
    when "update" then hash[:render] ||= "edit"
    else
      hash[:redirect] ||= eval("#{controller_name}_url")
    end

    hash[:json_code] ||= :unprocessable_entity
    logger.info "Failed to save: #{hash[:object].errors.full_messages.join(", ")}" if hash[:object].respond_to?(:errors)
    hash[:error_msg] ||= [hash[:object].errors[:base] + hash[:object].errors[:conflict].map{|e| "Conflict - #{e}"}].flatten
    hash[:error_msg] = [hash[:error_msg]].flatten
    respond_to do |format|
      format.html do
        hash[:error_msg] = hash[:error_msg].join("<br/>")
        if hash[:render]
          flash.now[:error] = hash[:error_msg] unless hash[:error_msg].empty?
          render hash[:render]
          return
        elsif hash[:redirect]
          error(hash[:error_msg]) unless hash[:error_msg].empty?
          redirect_to hash[:redirect]
          return
        end
      end
      format.json { render :json => {"errors" => hash[:object].errors.full_messages} , :status => hash[:json_code]}
    end
  end

  def redirect_back_or_to url
    redirect_to request.referer.empty? ? url : :back
  end

  def generic_exception(exception)
    logger.warn "Operation FAILED: #{exception}"
    logger.debug exception.backtrace.join("\n")
    render :template => "common/500", :layout => !request.xhr?, :status => 500, :locals => { :exception => exception}
  end

  def set_taxonomy
    return if User.current.nil?

    if SETTINGS[:organizations_enabled]
      orgs = Organization.my_organizations
      Organization.current = if orgs.count == 1 && !User.current.admin?
                               orgs.first
                             elsif session[:organization_id]
                               orgs.find(session[:organization_id])
                             else
                               nil
                             end
    end

    if SETTINGS[:locations_enabled]
      locations = Location.my_locations
      Location.current = if locations.count == 1 && !User.current.admin?
                           locations.first
                         elsif session[:location_id]
                           locations.find(session[:location_id])
                         else
                           nil
                         end
    end
  end

  def check_empty_taxonomy
    return if ["locations","organizations"].include?(controller_name)

    if User.current && User.current.admin?
      if SETTINGS[:locations_enabled] && Location.unconfigured?
        redirect_to locations_path, :notice => _("You must create at least one location before continuing.")
      elsif SETTINGS[:organizations_enabled] && Organization.unconfigured?
        redirect_to organizations_path, :notice => _("You must create at least one organization before continuing.")
      end
    end
  end

  # Returns the associations to include when doing a search.
  # If the user has a fact_filter then we need to include :fact_values
  # We do not include most associations unless we are processing a html page
  def included_associations(include = [])
    include += [:hostgroup, :compute_resource, :operatingsystem, :environment, :model ]
    include += [:fact_values] if User.current.user_facts.any?
    include
  end

end
