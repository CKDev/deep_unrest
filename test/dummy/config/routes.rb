Rails.application.routes.draw do
  resources :activities
  mount_devise_token_auth_for 'Admin', at: 'admin'
  mount_devise_token_auth_for 'Applicant', at: 'applicant'
  mount DeepUnrest::Engine => '/deep_unrest'

  jsonapi_resources :surveys
  jsonapi_resources :applicants
end
