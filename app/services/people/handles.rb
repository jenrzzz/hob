module People
  # One way of writing down an address (PEOPLE.md, "Person"), so the number
  # herald says and the number an agent typed are the same handle. A phone
  # number keeps its digits and a leading +; ten digits are taken as North
  # American (HOB_DEFAULT_COUNTRY_CODE, 1 by default). An email address is
  # lowercased. Anything else is kept as given, under `other`.
  module Handles
    EMAIL = /\A[^\s<>@,;"()]+@[^\s<>@,;"()]+\.[^\s<>@,;"()]+\z/
    PHONE = /\A\+?[\d\s().\-]{5,}\z/
    # Five- and six-digit senders are short codes: banks, pharmacies, 2FA.
    SHORT_CODE = /\A\d{3,6}\z/
    AUTOMATED_EMAIL = /\A(no-?reply|do-?not-?reply|notifications?|alerts?|mailer-daemon|bounces?|updates|news(letter)?)([+._-].*)?@/i

    module_function

    # -> [kind, address], or raises People::Invalid.
    def normalize(value, kind: nil)
      raise Invalid, "a handle is text: a phone number or an email address" unless value.is_a?(String) && value.strip.present?

      value = value.strip
      kind ||= infer(value)
      case kind
      when "email"
        raise Invalid, "#{value.inspect} is not an email address" unless value.match?(EMAIL)

        [ "email", value.downcase ]
      when "phone"
        [ "phone", phone(value) ]
      when "other"
        raise Invalid, "a handle is at most 320 characters" if value.length > 320

        [ "other", value ]
      else
        raise Invalid, "a handle's kind is phone, email, or other"
      end
    end

    def infer(value)
      return "email" if value.include?("@")
      return "phone" if value.match?(PHONE) || value.match?(SHORT_CODE)

      "other"
    end

    def phone(value)
      digits = value.gsub(/\D/, "")
      raise Invalid, "#{value.inspect} is not a phone number" if digits.length < 3 || digits.length > 15
      return digits if digits.length <= 6 && !value.start_with?("+") # a short code has no country
      return "+#{digits}" if value.start_with?("+")

      country = ENV.fetch("HOB_DEFAULT_COUNTRY_CODE", "1")
      digits.length == 10 ? "+#{country}#{digits}" : "+#{digits}"
    end

    # A sender that is a service, not a person: a short code, or a no-reply
    # address. Such a person is made `automated` and never opens a loop.
    def automated?(kind, address)
      (kind == "phone" && address.match?(SHORT_CODE)) || (kind == "email" && address.match?(AUTOMATED_EMAIL))
    end
  end
end
