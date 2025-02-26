defmodule NervesHubDevice.SSL do
  alias NervesHub.{Devices, Certificate}

  @type pkix_path_validation_reason ::
          :cert_expired
          | :invalid_issuer
          | :invalid_signature
          | :name_not_permitted
          | :missing_basic_constraint
          | :invalid_key_usage
          | {:revoked, :public_key.crl_reason()}
  @type reason ::
          :unknown_ca
          | :unknown_server_error
          | :registration_failed
          | :unknown_device_certificate
          | :mismatched_cert
          | :mismatched_org
          | :missing_common_name
          | :device_not_registered
          | pkix_path_validation_reason()
  @type event ::
          {:bad_cert, reason()}
          | {:extension, X509.Certificate.Extension.t()}
          | :valid
          | :valid_peer

  @spec verify_fun(X509.Certificate.t(), event(), any()) ::
          {:valid, any()} | {:fail, reason()} | {:unknown, any()}
  # The certificate is a valid_peer, which means it has been
  # signed by the NervesHub CA and the signer cert is still valid
  # or the signer cert was included by the client and is valid
  # for the peer (device) cert
  def verify_fun(otp_cert, :valid_peer, state) do
    do_verify(otp_cert, state)
  end

  def verify_fun(_certificate, :valid, state) do
    {:valid, state}
  end

  # The certificate failed peer validation.
  # This can happen if the Signer CA is not included in the request
  # and only the device cert/key is. Or if some other unknown CA
  # was included.
  def verify_fun(otp_cert, {:bad_cert, err}, state) when err in [:unknown_ca, :cert_expired] do
    aki = Certificate.get_aki(otp_cert)
    ski = Certificate.get_ski(otp_cert)

    if aki == ski do
      # Because Signer CAs are required to be registered first, we don't
      # really care about it coming in here. Likewise, if this is an
      # unregistered CA, we can just move on so that the device can
      # still attempt to present it's certificate to check if it has been
      # pinned or not. Veririfcation will fail there if the device cert
      # and it's signer CA is unknown
      {:valid, state}
    else
      do_verify(otp_cert, state)
    end
  end

  def verify_fun(_certificate, {:extension, _}, state) do
    {:valid, state}
  end

  defp do_verify(otp_cert, state) do
    case verify_cert(otp_cert) do
      {:ok, _db_cert} -> {:valid, state}
      {:error, {:bad_cert, reason}} -> {:fail, reason}
      {:error, _} -> {:fail, :registration_failed}
      reason when is_atom(reason) -> {:fail, reason}
      _ -> {:fail, :unknown_server_error}
    end
  end

  defp verify_cert(otp_cert) do
    # TODO: Maybe check for cert expiration
    #
    # We have always been ignoring expiration if we already have
    # the certificate stored, but in the future there might be reasons
    # to consider expirations for existing
    case Devices.get_device_certificate_by_x509(otp_cert) do
      {:ok, %{device: %{deleted_at: nil}} = db_cert} ->
        Devices.update_device_certificate(db_cert, %{last_used: DateTime.utc_now()})

      {:ok, _db_cert} ->
        :ignore_deleted_device

      _ ->
        maybe_register(otp_cert)
    end
  end

  defp maybe_register(otp_cert) do
    case Devices.get_device_certificates_by_public_key(otp_cert) do
      [] ->
        maybe_register_from_new_public_key(otp_cert)

      [%{device: %{deleted_at: nil} = device} | _] ->
        maybe_register_from_existing_public_key(otp_cert, device)

      _ ->
        :ignore_deleted_device
    end
  end

  # Registration attempt when public key is unknown
  defp maybe_register_from_new_public_key(otp_cert) do
    with {:ok, cn} <- check_common_name(otp_cert),
         {:ok, db_ca} <- check_known_ca(otp_cert),
         der = Certificate.to_der(otp_cert),
         verify_state = {X509.Certificate.from_der!(db_ca.der), !!db_ca.check_expiration},
         {:ok, _} <-
           :public_key.pkix_path_validation(db_ca.der, [der],
             verify_fun: {&path_verify/3, verify_state}
           ),
         {:ok, device} <- maybe_jitp_device(cn, db_ca),
         :ok <- check_new_public_key_allowed(device),
         params = params_from_otp_cert(otp_cert) do
      Devices.create_device_certificate(device, params)
    end
  end

  # Registration checks when device is known
  # This happens when public_key is matched in the DB,
  # but no DB certs matches the incoming OTP Cert der
  defp maybe_register_from_existing_public_key(otp_cert, device) do
    with {:ok, cn} <- check_common_name(otp_cert),
         true <- cn == device.identifier || :mismatched_cert,
         {:ok, db_ca} <- check_known_ca(otp_cert),
         true <- db_ca.org_id == device.org_id || :mismatched_org,
         der = Certificate.to_der(otp_cert),
         verify_state = {X509.Certificate.from_der!(db_ca.der), !!db_ca.check_expiration},
         {:ok, _} <-
           :public_key.pkix_path_validation(db_ca.der, [der],
             verify_fun: {&path_verify/3, verify_state}
           ),
         params = params_from_otp_cert(otp_cert) do
      Devices.create_device_certificate(device, params)
    end
  end

  defp path_verify(ca, {:bad_cert, :cert_expired}, {ca, _check_expiration? = false} = state) do
    # The Signer CA is technically expired, but expiration checks are disabled
    # so we should let this through the rest of the verification
    {:valid, state}
  end

  defp path_verify(_cert, {:bad_cert, reason}, _state) do
    {:fail, reason}
  end

  defp path_verify(_cert, event, state) when event in [:valid_peer, :valid] do
    {event, state}
  end

  defp path_verify(_certificate, {:extension, _}, state) do
    {:valid, state}
  end

  defp check_common_name(otp_cert) do
    case Certificate.get_common_name(otp_cert) do
      cn when is_binary(cn) and byte_size(cn) > 0 ->
        {:ok, cn}

      _ ->
        :missing_common_name
    end
  end

  defp check_known_ca(otp_cert) do
    Certificate.get_aki(otp_cert)
    |> Devices.get_ca_certificate_by_ski()
    |> case do
      {:ok, db_ca} ->
        # Mark that this CA cert was used
        Devices.update_ca_certificate(db_ca, %{last_used: DateTime.utc_now()})

      _ ->
        :unknown_ca
    end
  end

  defp maybe_jitp_device(cn, %{org_id: org_id, jitp: nil}) do
    case Devices.get_device_by(identifier: cn, org_id: org_id) do
      {:ok, %{deleted_at: nil}} = resp -> resp
      {:ok, _d} -> :ignore_deleted_device
      _ -> :device_not_registered
    end
  end

  defp maybe_jitp_device(cn, %{org_id: org_id, jitp: %Devices.CACertificate.JITP{} = jitp}) do
    case Devices.get_device_by(identifier: cn, org_id: org_id) do
      {:ok, %{deleted_at: nil}} = resp ->
        resp

      {:ok, _deleted} ->
        :ignore_deleted_device

      _ ->
        case Devices.create_device(%{
               identifier: cn,
               org_id: org_id,
               product_id: jitp.product_id,
               tags: jitp.tags,
               description: jitp.description
             }) do
          {:ok, _d} = resp -> resp
          _ -> :device_registration_failed
        end
    end
  end

  defp check_new_public_key_allowed(device) do
    case Devices.get_device_certificates(device) do
      [] ->
        # First time device connection. Allow
        :ok

      _ ->
        # TODO: Support device allowing multiple public keys?
        #
        # For now, expect that a device will only use one public key
        :unexpected_pubkey
    end
  end

  defp params_from_otp_cert(otp_cert) do
    {not_before, not_after} = Certificate.get_validity(otp_cert)

    %{
      aki: Certificate.get_aki(otp_cert),
      der: Certificate.to_der(otp_cert),
      last_used: DateTime.utc_now(),
      not_after: not_after,
      not_before: not_before,
      serial: Certificate.get_serial_number(otp_cert),
      ski: Certificate.get_ski(otp_cert)
    }
  end
end
