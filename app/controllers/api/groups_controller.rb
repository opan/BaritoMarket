class Api::GroupsController < Api::BaseController
  def index
    render json: { :groups => Group.all }, status: :ok
  end
end
