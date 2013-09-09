# Copyright 2013 Square Inc.
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.

# @abstract
#
# Abstract superclass of all controllers in the application. Unless otherwise
# noted in the controller documentation, all controllers follow the RESTful
# resource format as implemented in Rails.
#
# Supported Formats
# =================
#
# In general, the following formats are supported: HTML (`text/html`), JSON
# (`application/json`), and Atom (`application/atom+xml`). JSON requests are
# considered "API requests."
#
# Formats are indicated by the extension portion of the URL (e.g., ".json"), or
# the `Accepts` header. If no extension or header is given, HTML is assumed.
#
# Typical Responses
# =================
#
# Unless otherwise indicated by individual action method documentation, any
# RESTful request and response will follow the form shown below:
#
# All Actions
# -----------
#
# ### Record was successfully created
#
# If a record passes validation and is created, then...
#
# * for HTML requests, the response is a 302 Found redirect to the record's
#   `show` page.
# * for API requests, the status code 201 Created is returned. The body is a
#   representation of the resource in the API format.
#
# ### Record successfully updated
#
# If a record passes validation and is updated, then...
#
# * for HTML requests, the response is a 302 Found redirect to the record's
#   `show` page.
# * for API requests, the status code 200 OK is returned. The body is a
#   representation of the resource in the API format.
#
# ### Record destroyed
#
# If a record is destroyed, then...
#
# * for HTML requests, the response is a 302 Found redirect to some relevant
#   destination.
# * for API requests, the status code 204 No Content is returned. The body is
#   empty.
#
# ### Record not found
#
# If a record cannot be found, the status code 404 Not Found is returned. For
# HTML requests, a 404 page is rendered; for all other requests, no content is
# returned.
#
# ### Invalid field provided
#
# If an unknown or a protected field is included in a `create` or `update`
# request, then...
#
# * for HTML requests, the response is a 302 Found redirect to the root URL. A
#   flash alert is added indicating that the request was malformed.
# * for API requests, the status code 400 Bad Request is returned. The body is
#   empty.
#
# ### Record failed to validate
#
# If a record fails to validate during a `create` or `update` request, then...
#
# * for HTML requests, the form is re-rendered (without a redirect), and the
#   HTML is updated to indicate which fields are in error (status 200 OK).
# * for API requests, the status code 422 Unprocessable Entity is returned. The
#   body is a hash mapping model names (such as `project`) to a hash mapping
#   field names (such as `name`) to an array of error description fragments
#   (such as `is required`). Example:
#
# ```` json
# {
#   "project":{
#     "name":["is required"],
#     "repository_url":["is too long", "is not a valid URL"]
#   },
#   "user":{
#     "username":["is taken"]
#   }
# }
# ````
#
# ### Authentication required
#
# See the {AuthenticationHelpers#login_required} method for more information.
#
# CSRF Protection
# ===============
#
# All non-`GET` requests (HTML and API) must contain a correct authenticity
# token parameter. If your form is generated prior to the time of request, you
# can use the CSRF meta tags generated by the `csrf_meta_tags` function in
# Rails.

class ApplicationController < ActionController::Base
  include AuthenticationHelpers
  include "#{Squash::Configuration.authentication.strategy}_authentication_helpers".camelize.constantize

  include Squash::Ruby::ControllerMethods
  enable_squash_client

  if Rails.env.development?
    SQLOrigin::LIBRARY_PATHS << 'config/initializers/jdbc_fixes.rb'
    before_filter { SQLOrigin.append_to_log }
  end

  # Valid sort directions for a sort parameter.
  SORT_DIRECTIONS = %w(ASC DESC)

  layout false # handled by view class inheritance
  protect_from_forgery
  self.responder = JsonDetailResponder

  rescue_from(ActiveRecord::RecordNotFound) do
    respond_to do |format|
      format.html { render file: File.join(Rails.public_path, '404'), format: :html, status: :not_found }
      format.json { head :not_found }
      format.atom { head :not_found }
    end
  end

  rescue_from(ActionController::UnpermittedParameters) do |error|
    respond_to do |format|
      format.html { render file: File.join(Rails.public_path, '400'), format: :html, status: :bad_request }
      format.json do
        render json: {error: "The following parameters cannot be modified: #{error.params.join(', ')}" }, status: :bad_request
      end
      format.atom { head :bad_request }
    end
  end

  before_filter :login_required

  protected

  # Generates a SQL `WHERE` clause to load the next page of rows for an infinite
  # scrolling implementation. It is assumed that the controller can load the
  # last object of the previous page.
  #
  # @param [String] column The column that the rows are sorted by.
  # @param [String] dir The sort direction ("ASC" or "DESC").
  # @param [ActiveRecord::Base] last The last object of the last page.
  # @param [String] key The column that is used to identify the last object of a
  #   page (by default equal to `column`). You would typically set this
  #   parameter to a globally unique column when your sort column is not
  #   guaranteed to be globally unique (to ensure that edge records are not
  #   loaded in two different pages).
  # @return [String] A SQL `WHERE` clause to load the next page of rows.
  #
  # @example Sorting by `created_at` but keying by `id`
  #   last = Model.find_by_id(params[:last])
  #   if last
  #     @records = Model.where(infinite_scroll_clause('created_at', 'DESC', last, 'id')).order('created_at DESC').limit(50)
  #   else
  #     @records = Model.order('created_at DESC').limit(50)
  #   end

  def infinite_scroll_clause(column, dir, last, key=nil)
    field      = column.split('.').last
    last_value = last.send(field)

    if key
      key_field = key.split('.').last
      last_key  = last.send(key_field)
    end

    case dir.upcase
      when 'ASC'
        if key
          ["#{column} > ? OR (#{column} = ? AND #{key} > ?)", last_value, last_value, last_key]
        else
          ["#{column} > ?", last_value]
        end
      when 'DESC'
        if key
          ["#{column} < ? OR (#{column} = ? AND #{key} < ?)", last_value, last_value, last_key]
        else
          ["#{column} < ?", last_value]
        end
      else
        'TRUE'
    end
  end

  # @return [Kramdown::Document] A Markdown renderer that can be used to render
  # comment bodies. Also available in views.

  def markdown
    $markdown ||= ->(text) { Kramdown::Document.new(text).to_html }
  end
  helper_method :markdown

  private

  def find_project
    @project = Project.find_from_slug!(params[:project_id])
  end

  def find_environment
    @environment = @project.environments.with_name(params[:environment_id]).first!
  end

  def find_bug
    @bug = @environment.bugs.find_by_number!(params[:bug_id])
  end

  def membership_required
    if current_user.role(@project)
      return true
    else
      respond_to do |format|
        format.json { head :forbidden }
        format.html { redirect_to root_url }
      end
    end
  end

  def admin_login_required
    if [:owner, :admin].include? current_user.role(@project)
      return true
    else
      respond_to do |format|
        format.json { head :forbidden }
        format.html { redirect_to root_url }
      end
    end
  end

  def owner_login_required
    if current_user.role(@project) == :owner then
      return true
    else
      respond_to do |format|
        format.html { redirect_to root_url }
        format.json { head :forbidden }
      end
      return false
    end
  end
end
