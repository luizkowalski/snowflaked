# frozen_string_literal: true

# Appraisals
# Run `bundle exec appraisal install` to generate the gemfiles under gemfiles/.
# Then run tests with `bundle exec appraisal <rails_version> rake`.

appraise "rails-7.2" do
  gem "rails", "~> 7.2"
  gem "net-imap", ">= 0.6.0"
  gem "minitest", "< 6"
end

appraise "rails-8.0" do
  gem "rails", "~> 8.0", "< 8.1"
  gem "uri", "1.1.1"
  gem "net-imap", ">= 0.6.0"
  gem "minitest", "< 6"
end

appraise "rails-8.1" do
  gem "rails", "~> 8.1"
end

appraise "rails-main" do
  gem "rails",         github: "rails/rails", branch: "main"
  gem "railties",      github: "rails/rails", branch: "main"
  gem "activerecord",  github: "rails/rails", branch: "main"
  gem "activesupport", github: "rails/rails", branch: "main"
end
