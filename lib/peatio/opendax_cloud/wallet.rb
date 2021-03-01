module OpendaxCloud
  class Wallet < Peatio::Wallet::Abstract
    Error = Class.new(StandardError)
    DEFAULT_FEATURES = { skip_deposit_collection: true }.freeze

    def initialize(custom_features = {})
      @features = DEFAULT_FEATURES.merge(custom_features).slice(*SUPPORTED_FEATURES)
      @settings = {}
    end

    def configure(settings = {})
      # Clean client state during configure.
      @client = nil

      @settings.merge!(settings.slice(*SUPPORTED_SETTINGS))

      @wallet = @settings.fetch(:wallet) do
        raise Peatio::Wallet::MissingSettingError, :wallet
      end.slice(:uri, :address)

      @currency = @settings.fetch(:currency) do
        raise Peatio::Wallet::MissingSettingError, :currency
      end.slice(:id, :base_factor, :options)
    end

    def create_address!(_options = {})
      response = client.rest_api(:post, '/address/new', {
                                   currency_id: currency_id
                                 })

      { address: response['address'], details: response.except('address') }
    rescue OpendaxCloud::Client::Error => e
      raise Peatio::Wallet::ClientError, e
    end

    def create_transaction!(transaction)
      response = client.rest_api(:post, '/tx/send', {
                        currency_id: currency_id,
                        to: transaction.to_address,
                        amount: transaction.amount,
                        options: transaction.options
                      })
      transaction.options = response['options']
      transaction
    rescue OpendaxCloud::Client::Error => e
      raise Peatio::Wallet::ClientError, e
    end

    def load_balance!
      response = client.rest_api(:post, '/address/balance', {
        currency_id: currency_id
      }.compact).fetch('balance')

      response.to_d
    rescue OpendaxCloud::Client::Error => e
      raise Peatio::Wallet::ClientError, e
    end

    def trigger_webhook_event(request)
      public_key = OpenSSL::PKey.read(Base64.urlsafe_decode64(ENV.fetch('OPENFINEX_CLOUD_PUBLIC_KEY')))
      params = JWT.decode(request.body.string, public_key, true, { algorithm: 'RS256' }).first.with_indifferent_access

      [
        Peatio::Transaction.new(
          currency_id: params[:currency],
          amount: params[:amount], # TODO convert from base unit or not?
          hash: params[:blockchain_txid],
          # If there is no rid field, it means we have deposit
          to_address: params[:rid] || params[:address],
          txout: 0,
          status: params[:state],
          options: {
            tid: params[:tid]
          })
      ]
    rescue OpendaxCloud::Client::Error => e
      raise Peatio::Wallet::ClientError, e
    end

    def convert_from_base_unit(value, currency)
      value.to_d / currency.fetch(:base_factor).to_d
    end

    def currency_id
      @currency.fetch(:id)
    end

    def client
      @client ||= Client.new(@wallet.fetch(:uri), idle_timeout: 1)
    end
  end
end