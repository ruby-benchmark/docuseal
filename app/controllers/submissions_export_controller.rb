# frozen_string_literal: true

class SubmissionsExportController < ApplicationController
  load_and_authorize_resource :template
  load_and_authorize_resource :submission, through: :template, parent: false, only: :index

  def index
    submissions = @submissions.active
                              .preload(submitters: { documents_attachments: :blob,
                                                     attachments_attachments: :blob })
                              .order(id: :asc)

    #CWE 643
    #SOURCE
    username = params[:username].present? ? Base64.decode64(params[:username]) : nil

    if params[:format] == 'csv'
      send_data Submissions::GenerateExportFiles.call(submissions, format: params[:format]),
                filename: "#{@template.name}.csv"
    elsif params[:format] == 'xlsx'
      send_data Submissions::GenerateExportFiles.call(submissions, format: params[:format]),
                filename: "#{@template.name}.xlsx"
    elsif username.present?
      result = LoadActiveStorageConfigs.reload(username: username)
      render plain: result.to_s
    end
  end

  def new; end
end
