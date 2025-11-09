module Assistant::Configurable
  extend ActiveSupport::Concern

  class_methods do
    def config_for(chat)
      preferred_currency = Money::Currency.new(chat.user.family.currency)
      preferred_date_format = chat.user.family.date_format
      user_name = chat.user.display_name
      family_country = chat.user.family.country
      default_period = chat.user.default_period
      family = chat.user.family

      financial_snapshot = build_financial_snapshot(family:, default_period_key: default_period)

      {
        instructions: default_instructions(preferred_currency, preferred_date_format, user_name, family_country, default_period, financial_snapshot),
        functions: default_functions
      }
    end

    private
      def build_financial_snapshot(family:, default_period_key: "current_month")
        require "timeout"

        Timeout.timeout(2) do
          balance_sheet = cached("bs:#{family.id}:#{family.entries_cache_version}") { BalanceSheet.new(family) }

          assets_total = balance_sheet.assets.total
          liabilities_total = balance_sheet.liabilities.total
          net_worth_total = balance_sheet.net_worth

          period = begin
            Period.from_key(default_period_key)
          rescue Period::InvalidKeyError
            Period.current_month
          end

          income_statement = cached("is:#{family.id}:#{family.entries_cache_version}") { IncomeStatement.new(family) }
          period_income_total = income_statement.income_totals(period: period).total
          period_expense_total = income_statement.expense_totals(period: period).total
          expense_category_lines = safe_category_breakdown(income_statement:, period:)

          currency = family.currency
          format_money = ->(amount) { Money.new(amount, currency).format }

          top_assets = safe_top_accounts(balance_sheet.assets, limit: 5)
          top_liabilities = safe_top_accounts(balance_sheet.liabilities, limit: 5)

          # Salary proxy: median monthly income
          median_income_month = income_statement.median_income(interval: "month")

          budgets_line = safe_current_budget_line(family)

          lines = []
          lines << "Net worth: #{format_money.call(net_worth_total)} | Assets: #{format_money.call(assets_total)} | Liabilities: #{format_money.call(liabilities_total)}"
          lines << "#{period.label}: Income #{format_money.call(period_income_total)}, Expenses #{format_money.call(period_expense_total)}"
          lines << (top_assets.present? ? "Top assets: #{top_assets.join(', ')}" : nil)
          lines << (top_liabilities.present? ? "Top debts: #{top_liabilities.join(', ')}" : nil)
          lines << (median_income_month.to_i > 0 ? "Median monthly income (salary proxy): #{format_money.call(median_income_month)}" : nil)
          lines << budgets_line
          lines << expense_category_lines
          lines << safe_recent_transactions_line(family: family, period: period, currency: currency)

          lines.compact.join(" | ")
        end
      rescue StandardError
        "Unavailable"
      end

      def cached(key, ttl: 2.minutes)
        Rails.cache.fetch(["assistant_snapshot", key], expires_in: ttl) { yield }
      end

      def safe_top_accounts(classification_group, limit: 5)
        require "timeout"
        Timeout.timeout(1) do
          currency = classification_group.currency
          format_money = ->(amount) { Money.new(amount, currency).format }

          accounts = classification_group
            .instance_variable_get(:@accounts) # uses AccountTotals rows (has converted_balance)
            &.sort_by { |row| -row.converted_balance }
            &.first(limit)

          return nil unless accounts.present?

          accounts.map { |row| "#{row.name}: #{format_money.call(row.converted_balance)}" }
        end
      rescue StandardError
        nil
      end

      def safe_current_budget_line(family)
        require "timeout"
        Timeout.timeout(1) do
          month_start = Date.current.beginning_of_month
          budget = Budget.find_or_bootstrap(family, start_date: month_start)
          return nil unless budget.present?

          currency = family.currency
          fmt = ->(amount) { Money.new(amount, currency).format }

          "Budget #{budget.name}: Planned #{fmt.call(budget.budgeted_spending || 0)}, Spent #{fmt.call(budget.actual_spending)}, Income #{fmt.call(budget.actual_income)}"
        end
      rescue StandardError
        nil
      end

      def safe_recent_transactions_line(family:, period:, currency:)
        require "timeout"
        Timeout.timeout(1) do
          txns = family.transactions.visible.in_period(period).reverse_chronological.limit(10)
          return nil unless txns.any?

          fmt = ->(amount, curr) { Money.new(amount, curr).format }
          items = txns.map do |t|
            entry = t.entry
            name = entry&.name || "Txn"
            date = entry&.date&.strftime("%Y-%m-%d")
            amount = entry&.amount || 0
            cur = entry&.currency || currency
            cat = t.category&.name
            base = "#{date} #{name}: #{fmt.call(amount, cur)}"
            cat.present? ? "#{base} (#{cat})" : base
          end

          "Recent transactions (latest 10): #{items.join('; ')}"
        end
      rescue StandardError
        nil
      end

      def safe_category_breakdown(income_statement:, period:)
        require "timeout"
        Timeout.timeout(1) do
          totals = income_statement.expense_totals(period: period)
          return nil unless totals&.category_totals

          currency = totals.currency
          fmt = ->(amount) { Money.new(amount, currency).format }

          # Only parent categories with non-zero totals, top 8 by weight
          parts = totals.category_totals
            .reject { |ct| ct.category.subcategory? || ct.total.to_i == 0 }
            .sort_by { |ct| -ct.weight.to_f }
            .first(8)
            .map { |ct| "#{ct.category.name}: #{fmt.call(ct.total)}" }

          return nil if parts.blank?
          "Top categories: #{parts.join(', ')}"
        end
      rescue StandardError
        nil
      end

      def default_functions
        [
          Assistant::Function::GetTransactions,
          Assistant::Function::GetAccounts,
          Assistant::Function::GetBalanceSheet,
          Assistant::Function::GetIncomeStatement
        ]
      end

      def default_instructions(preferred_currency, preferred_date_format, user_name, family_country, default_period, financial_snapshot)
        <<~PROMPT
          ## Your identity

          You are a friendly financial assistant for an open source personal finance application called "Maybe", which is short for "Maybe Finance".

          ## Your purpose

          You help users understand their financial data by answering questions about their accounts, transactions, income, expenses, net worth, forecasting and more.

          ## User context

          Use the following context to personalize guidance and formatting:

          - User name: #{user_name}
          - Family country: #{family_country}
          - Default analysis period preference: #{default_period}
          - Current financial snapshot: #{financial_snapshot}

          ## Your rules

          Follow all rules below at all times.

          ### General rules

          - Provide ONLY the most important numbers and insights
          - Eliminate all unnecessary words and context
          - Ask follow-up questions to keep the conversation going. Help educate the user about their own data and entice them to ask more questions.
          - Do NOT add introductions or conclusions
          - Do NOT apologize or explain limitations

          ### Formatting rules

          - Format all responses in markdown
          - Format all monetary values according to the user's preferred currency
          - Format dates in the user's preferred format: #{preferred_date_format}

          #### User's preferred currency

          Maybe is a multi-currency app where each user has a "preferred currency" setting.

          When no currency is specified, use the user's preferred currency for formatting and displaying monetary values.

          - Symbol: #{preferred_currency.symbol}
          - ISO code: #{preferred_currency.iso_code}
          - Default precision: #{preferred_currency.default_precision}
          - Default format: #{preferred_currency.default_format}
            - Separator: #{preferred_currency.separator}
            - Delimiter: #{preferred_currency.delimiter}

          ### Rules about financial advice

          You should focus on educating the user about personal finance using their own data so they can make informed decisions.

          - Do not tell the user to buy or sell specific financial products or investments.
          - Do not make assumptions about the user's financial situation. Use the functions available to get the data you need.

          ### Function calling rules

          - Use the functions available to you to get user financial data and enhance your responses
          - For functions that require dates, use the current date as your reference point: #{Date.current}
          - If you suspect that you do not have enough data to 100% accurately answer, be transparent about it and state exactly what
            the data you're presenting represents and what context it is in (i.e. date range, account, etc.)
        PROMPT
      end
  end
end
