class Api::ServicesController < Api::BaseController
  before_action :set_service, only: [:show]

  def show
    return service_not_found if @service.nil?
    render json: { :services => @service }, status: :ok
  end

  private

  def service_not_found
    render json: { errors: I18n.t('controllers.errors.service.not_found') }.to_json, status: :not_found
  end

  def set_service(service_id = :id)
    @service = Service.find_by_id(params.require(service_id))
  end
end
