class PagesController < ApplicationController
  include Periodable

  skip_authentication only: :redis_configuration_error

  def dashboard
    # Cache expensive calculations for 5 minutes to improve performance
    cache_key = "dashboard_#{Current.family.id}_#{params[:cashflow_period] || 'last_30_days'}_#{Current.family.updated_at.to_i}"

    @balance_sheet, @accounts, @cashflow_sankey_data = Rails.cache.fetch(cache_key, expires_in: 5.minutes) do
      balance_sheet = Current.family.balance_sheet
      accounts = Current.family.accounts.visible.includes(:logo_attachment)

      period_param = params[:cashflow_period]
      cashflow_period = if period_param.present?
        begin
          Period.from_key(period_param)
        rescue Period::InvalidKeyError
          Period.last_30_days
        end
      else
        Period.last_30_days
      end

      family_currency = Current.family.currency
      income_totals = Current.family.income_statement.income_totals(period: cashflow_period)
      expense_totals = Current.family.income_statement.expense_totals(period: cashflow_period)

      sankey_data = build_cashflow_sankey_data(income_totals, expense_totals, family_currency)

      [balance_sheet, accounts, sankey_data]
    end

    # Set period for view (not cached since it's simple)
    @cashflow_period = if params[:cashflow_period].present?
      begin
        Period.from_key(params[:cashflow_period])
      rescue Period::InvalidKeyError
        Period.last_30_days
      end
    else
      Period.last_30_days
    end

    @breadcrumbs = [ [ "Home", root_path ], [ "Dashboard", nil ] ]
  end

  def changelog
    @release_notes = github_provider.fetch_latest_release_notes

    # Fallback if no release notes are available
    if @release_notes.nil?
      @release_notes = {
        avatar: "https://github.com/maybe-finance.png",
        username: "maybe-finance",
        name: "Release notes unavailable",
        published_at: Date.current,
        body: "<p>Unable to fetch the latest release notes at this time. Please check back later or visit our <a href='https://github.com/maybe-finance/maybe/releases' target='_blank'>GitHub releases page</a> directly.</p>"
      }
    end

    render layout: "settings"
  end

  def feedback
    render layout: "settings"
  end

  def redis_configuration_error
    render layout: "blank"
  end

  private
    def github_provider
      Provider::Registry.get_provider(:github)
    end

    def build_cashflow_sankey_data(income_totals, expense_totals, currency_symbol)
      nodes = []
      links = []
      node_indices = {} # Memoize node indices by a unique key: "type_categoryid"

      # Helper to add/find node and return its index
      add_node = ->(unique_key, display_name, value, percentage, color) {
        node_indices[unique_key] ||= begin
          nodes << { name: display_name, value: value.to_f.round(2), percentage: percentage.to_f.round(1), color: color }
          nodes.size - 1
        end
      }

      total_income_val = income_totals.total.to_f.round(2)
      total_expense_val = expense_totals.total.to_f.round(2)

      # --- Create Central Cash Flow Node ---
      cash_flow_idx = add_node.call("cash_flow_node", "Cash Flow", total_income_val, 0, "var(--color-success)")

      # --- Process Income Side (Top-level categories only) ---
      income_totals.category_totals.each do |ct|
        # Skip subcategories – only include root income categories
        next if ct.category.parent_id.present?

        val = ct.total.to_f.round(2)
        next if val.to_f == 0

        percentage_of_total_income = total_income_val.to_f == 0 ? 0 : (val / total_income_val * 100).round(1)

        node_display_name = ct.category.name
        node_color = ct.category.color.presence || Category::COLORS.sample

        current_cat_idx = add_node.call(
          "income_#{ct.category.id}",
          node_display_name,
          val,
          percentage_of_total_income,
          node_color
        )

        links << {
          source: current_cat_idx,
          target: cash_flow_idx,
          value: val,
          color: node_color,
          percentage: percentage_of_total_income
        }
      end

      # --- Process Expense Side (Top-level categories only) ---
      expense_totals.category_totals.each do |ct|
        # Skip subcategories – only include root expense categories to keep Sankey shallow
        next if ct.category.parent_id.present?

        val = ct.total.to_f.round(2)
        next if val.to_f == 0

        percentage_of_total_expense = total_expense_val.to_f == 0 ? 0 : (val / total_expense_val * 100).round(1)

        node_display_name = ct.category.name
        node_color = ct.category.color.presence || Category::UNCATEGORIZED_COLOR

        current_cat_idx = add_node.call(
          "expense_#{ct.category.id}",
          node_display_name,
          val,
          percentage_of_total_expense,
          node_color
        )

        links << {
          source: cash_flow_idx,
          target: current_cat_idx,
          value: val,
          color: node_color,
          percentage: percentage_of_total_expense
        }
      end

      # --- Process Surplus ---
      leftover = (total_income_val - total_expense_val).round(2)
      if leftover.to_f > 0
        percentage_of_total_income_for_surplus = total_income_val.to_f == 0 ? 0 : (leftover / total_income_val * 100).round(1)
        surplus_idx = add_node.call("surplus_node", "Surplus", leftover, percentage_of_total_income_for_surplus, "var(--color-success)")
        links << { source: cash_flow_idx, target: surplus_idx, value: leftover, color: "var(--color-success)", percentage: percentage_of_total_income_for_surplus }
      end

      # Update Cash Flow and Income node percentages (relative to total income)
      if node_indices["cash_flow_node"]
        nodes[node_indices["cash_flow_node"]][:percentage] = 100.0
      end
      # No primary income node anymore, percentages are on individual income cats relative to total_income_val

      { nodes: nodes, links: links, currency_symbol: Money::Currency.new(currency_symbol).symbol }
    end
end
