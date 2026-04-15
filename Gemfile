# frozen_string_literal: true

source "https://rubygems.org"

# LLM execution layer (1.x removed Ollama::Agent::Planner — keep 0.2.x API this code expects)
gem "ollama-client", "~> 0.2", "< 1"

# Market data
gem "coindcx-client", "~> 0.1"

# Technical analysis
gem "indicators", "~> 1.0" # TA-Lib style indicators

# Data handling
gem "numo-narray"           # Numeric arrays for fast computation
gem "csv"

# Schema validation
gem "json_schemer", "~> 2.0"

# Configuration
gem "dry-configurable", "~> 1.0"
gem "dotenv", "~> 3.0"

# Logging
gem "semantic_logger", "~> 4.0"

# CLI
gem "thor", "~> 1.3"
gem "tty-table", "~> 0.12"
gem "tty-progressbar", "~> 0.18"
gem "tty-spinner", "~> 0.9"
gem "pastel", "~> 0.8"

group :development, :test do
  gem "rspec", "~> 3.13"
  gem "rubocop", "~> 1.60"
  gem "webmock", "~> 3.19"
  gem "vcr", "~> 6.2"
  gem "factory_bot", "~> 6.4"
  gem "debug"
end
