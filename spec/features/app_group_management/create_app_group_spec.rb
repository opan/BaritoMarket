require 'rails_helper'

RSpec.feature 'Application Group Management', type: :feature do
  let(:user_a) { create(:user) }
  let(:user_b) { create(:user) }

  describe 'Create applications group' do
    context 'As Superadmin' do
      scenario 'User can create new application group' do
        set_check_user_groups({ 'groups': ['barito-superadmin'] })
        login_as user_a
        create(:group, name: 'barito-superadmin')
        prep_app_group = build(:app_group)

        visit root_path

        click_link 'New Application Group'
        within('#app_group_form') do
          fill_in 'app_group_name', with: prep_app_group.name
          select TPS_CONFIG.keys[0], from: 'app_group[capacity]'
        end

        click_button 'Submit'
        expect(page).to have_content(prep_app_group.name)
      end
    end

    context 'As other User' do
      scenario 'User cannot create new application group' do
        set_check_user_groups({ 'groups' => [] })
        login_as user_a
        visit root_path

        expect(page).not_to have_content('New Application Group')
      end
    end
  end
end
