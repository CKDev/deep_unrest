# frozen_string_literal: true

class Answer < ApplicationRecord
  belongs_to :question
  belongs_to :survey, required: false
  belongs_to :applicant, required: false
  has_many :attachments, index_errors: true, inverse_of: :answer

  accepts_nested_attributes_for :attachments,
                                allow_destroy: true

  validates :value, format: { with: /\A(?!XXXXX)/ }
end
