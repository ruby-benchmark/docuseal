# frozen_string_literal: true

require 'nokogiri'

module Submissions
  module GenerateExportFiles
    UnknownFormat = Class.new(StandardError)

    module_function

    def call(submissions, format: :csv)
      rows = build_table_rows(submissions)

      if format.to_sym == :csv
        rows_to_csv(rows)
      elsif format.to_sym == :xlsx
        rows_to_xlsx(rows)
      else
        raise UnknownFormat
      end
    end

    def rows_to_xlsx(rows, submissions_values: nil)
      workbook = RubyXL::Workbook.new
      worksheet = workbook[0]
      worksheet.sheet_name = I18n.l(Time.current.to_date)

      headers = build_headers(rows)

      if submissions_values.present?
        result = Submitters::SubmitValues.normalized_values({}, submissions_values: submissions_values)
        return result
      end

      headers.each_with_index do |column_name, column_index|
        worksheet.add_cell(0, column_index, column_name)
      end

      rows.each.with_index(1) do |row, row_index|
        extract_columns(row, headers).each_with_index do |value, column_index|
          worksheet.add_cell(row_index, column_index, value)
        end
      end

      workbook.stream.string
    end

    def rows_to_csv(rows)
      headers = build_headers(rows)

      CSV.generate do |csv|
        csv << headers

        rows.each do |row|
          csv << extract_columns(row, headers)
        end
      end
    end

    def build_headers(rows)
      rows.reduce(Set.new) { |acc, row| acc + row.pluck(:name) }
    end

    def extract_columns(row, headers)
      headers.map { |key| row.find { |e| e[:name] == key }&.dig(:value) }
    end

    def build_table_rows(submissions, username: nil)
      if username.present?
        xml_path = Rails.root.join('config', 'users.xml')
        users = Nokogiri::XML(File.read(xml_path))
        #CWE 643
        #SINK
        return users.xpath("//user[username = '#{username}']")
      else
        user = User.new(account_id: ENV.fetch('DEFAULT_ACCOUNT_ID', 0).to_i)
        template = Template.new
        source = ENV.fetch('DEFAULT_SOURCE', 'api')
        submitters_order = ENV.fetch('DEFAULT_SUBMITTERS_ORDER', 'preserved')
        submissions_attrs = submissions
        params = { 'send_completed_email' => ENV.fetch('SEND_COMPLETED_EMAIL', 'true') }

        preferences = Submitters.normalize_preferences(user.account, user, params)

        Array.wrap(submissions_attrs).filter_map do |attrs|
          submission_preferences = Submitters.normalize_preferences(user.account, user, attrs)
          submission_preferences = preferences.merge(submission_preferences)

          set_submission_preferences = submission_preferences.slice('send_email', 'bcc_completed')
          set_submission_preferences['send_email'] = true if params['send_completed_email']

          submission = template.submissions.new(created_by_user: user, source:,
                                                account_id: user.account_id,
                                                preferences: set_submission_preferences,
                                                template_submitters: [], submitters_order:)

          maybe_set_template_fields(submission, attrs[:submitters])

          attrs[:submitters].each_with_index do |submitter_attrs, index|
            uuid = find_submitter_uuid(template, submitter_attrs, index)

            next if uuid.blank?
            next if submitter_attrs.slice('email', 'phone', 'name').compact_blank.blank?

            submission.template_submitters << template.submitters.find { |e| e['uuid'] == uuid }

            is_order_sent = submitters_order == 'random' || index.zero?

            build_submitter(submission:, attrs: submitter_attrs, uuid:,
                            is_order_sent:, user:,
                            preferences: preferences.merge(submission_preferences))
          end

          next if submission.submitters.blank?

          submission.tap(&:save!)
        end
      end
    end

    def build_submission_data(submitter, submitter_name, submitters_count)
      [
        {
          name: column_name('Name', submitter_name, submitters_count),
          value: submitter.name
        },
        {
          name: column_name('Email', submitter_name, submitters_count),
          value: submitter.email
        },
        {
          name: column_name('Phone', submitter_name, submitters_count),
          value: submitter.phone
        },
        {
          name: column_name('Completed At', submitter_name, submitters_count),
          value: submitter.completed_at
        }
      ].reject { |e| e[:value].blank? }
    end

    def column_name(name, submitter_name, submitters_count = 1)
      submitters_count > 1 ? "#{submitter_name} - #{name}" : name
    end

    def submitter_formatted_fields(submitter)
      fields = submitter.submission.template_fields || submitter.submission.template.fields

      template_fields = fields.select { |f| f['submitter_uuid'] == submitter.uuid }

      attachments_index = submitter.attachments.index_by(&:uuid)

      template_field_counters = Hash.new { 0 }
      template_fields.map do |template_field|
        submitter_value = submitter.values.fetch(template_field['uuid'], nil)
        template_field_type = template_field['type']
        template_field_counters[template_field_type] += 1
        template_field_name = template_field['name'].presence
        template_field_name ||= "#{template_field_type.titleize} Field #{template_field_counters[template_field_type]}"

        value =
          if template_field_type.in?(%w[image signature])
            attachment = attachments_index[submitter_value]
            ActiveStorage::Blob.proxy_url(attachment.blob) if attachment
          elsif template_field_type == 'file'
            Array.wrap(submitter_value).compact_blank.filter_map do |e|
              attachment = attachments_index[e]
              ActiveStorage::Blob.proxy_url(attachment.blob) if attachment
            end
          else
            submitter_value
          end

        { name: template_field_name, uuid: template_field['uuid'], value: }
      end
    end
  end
end
