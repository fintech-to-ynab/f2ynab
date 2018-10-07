module F2ynab
  module Webhooks
    class Monzo
      attr_accessor :webhook, :ynab_account_id

      def initialize(webhook, ynab_account_id: nil)
        @webhook = webhook
        @ynab_account_id = ynab_account_id
      end

      def import
        return { warning: :unsupported_type } unless webhook[:type] == 'transaction.created'
        return { warning: :zero_value } if webhook[:data][:amount] == 0
        return { warning: :declined } if webhook[:data][:decline_reason].present?

        payee_name = webhook[:data][:merchant].try(:[], :name)
        payee_name ||= webhook[:data][:counterparty][:name] if webhook[:data][:counterparty].present?
        payee_name ||= 'Topup' if webhook[:data][:metadata][:is_topup]
        payee_name ||= webhook[:data][:description]

        description = ''
        flag = nil

        foreign_transaction = webhook[:data][:local_currency] != webhook[:data][:currency]
        if foreign_transaction
          money = ::Money.new(webhook[:data][:local_amount].abs, webhook[:data][:local_currency])
          description.prepend("(#{money.format}) ")
          flag = 'orange' unless ENV['SKIP_FOREIGN_CURRENCY_FLAG'].present?
        end

        unless ENV['SKIP_EMOJI'].present?
          description.prepend("#{webhook[:data][:merchant][:emoji]} ") if webhook[:data][:merchant].try(:[], :emoji)
        end

        unless ENV['SKIP_TAGS'].present?
          description << webhook[:data][:merchant][:metadata][:suggested_tags] if webhook[:data][:merchant].try(:[], :metadata).try(:[], :suggested_tags)
        end

        # If this is a split repayment, then add that to the description
        if webhook[:data][:metadata].try(:[], :p2p_initiator) == 'payment-request' && webhook[:data][:merchant].present? && webhook[:data][:counterparty].present?
          description << " (Repayment to #{webhook[:data][:counterparty][:name]})"
        end

        # @todo remove the final fall back at some point. It will be a breaking change.
        ynab_account_id = ynab_account_id || ENV['YNAB_MONZO_ACCOUNT_ID'] || ENV['YNAB_ACCOUNT_ID']

        ::F2ynab::YNAB::TransactionCreator.new(
          id: "M#{webhook[:data][:id]}",
          date: Time.parse(webhook[:data][:created]).to_date,
          amount: webhook[:data][:amount] * 10,
          payee_name: payee_name,
          description: description.strip,
          cleared: !foreign_transaction,
          flag: flag,
          account_id: ynab_account_id
        ).create
      end
    end
  end
end