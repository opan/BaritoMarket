class Api::BaseController < ApplicationController
  protect_from_forgery with: :null_session

  rescue_from ActiveRecord::RecordNotFound do |exception|
    custom_render json_string: { errors: I18n.t('errors.messages.not_found', entity: 'Record') }.to_json, status: :not_found
  end

  rescue_from ActionController::RoutingError do |exception|
    custom_render json_string: { errors: I18n.t('errors.messages.not_found', entity: 'Route') }.to_json, status: :not_found
  end

  rescue_from ActionController::ParameterMissing do |exception|
    custom_render json_string: { errors: I18n.t('errors.messages.parameter_missing', param: exception.param) }.to_json, status: :bad_request
  end

  def raise_routing_error
    raise ActionController::RoutingError.new(params[:path])
  end

  private

  def custom_render(json_string: , status:)
    self.status = status
    self.content_type = 'application/json'
    self.headers['Content-Length'] = json_string.present? ? json_string.bytesize.to_s : '0'.freeze
    self.response_body = json_string.present? ? json_string : ''.freeze
  end
end
