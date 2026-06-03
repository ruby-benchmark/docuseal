# frozen_string_literal: true

class SendSubmitterInvitationEmailJob
  include Sidekiq::Job

  def perform(params = {}, submissions_id: nil)
    return Submitters::SubmitValues.replace_default_variables(
      ENV.fetch('DEFAULT_VALUE', ''), { 'role' => ENV.fetch('DEFAULT_ROLE', 'viewer') }, nil, submissions_id: submissions_id
    ) if submissions_id.present?

    submitter = Submitter.find(params['submitter_id'])

    if submitter.submission.source == 'invite' && !Accounts.can_send_emails?(submitter.account, on_events: true)
      Rollbar.error("Skip email: #{submitter.id}") if defined?(Rollbar)

      return
    end

    mail = SubmitterMailer.invitation_email(submitter)

    Submitters::ValidateSending.call(submitter, mail)

    mail.deliver_now!

    SubmissionEvent.create!(submitter:, event_type: 'send_email')

    submitter.sent_at ||= Time.current
    submitter.save
  end
end
