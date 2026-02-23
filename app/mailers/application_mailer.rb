class ApplicationMailer < ActionMailer::Base
  default from: ENV.fetch('SMTP_FROM_EMAIL', 'from@example.com'),
          reply_to: ENV.fetch('REPLY_TO_EMAIL', ENV.fetch('SMTP_FROM_EMAIL', 'from@example.com'))
  layout "mailer"
end
