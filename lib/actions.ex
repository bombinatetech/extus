defmodule ExTus.Actions do
  import Plug.Conn
  alias ExTus.Utils
  alias ExTus.UploadInfo
  alias ExTus.UploadCache
  require Logger

  defp storage() do
    Application.get_env(:extus, :storage, ExTus.Storage.Local)
  end

  def options(conn)do
    Logger.info("[TUS][OPTIONS: #{inspect({ExTus.Config.tus_api_version, ExTus.Config.tus_api_version_supported, to_string(ExTus.Config.tus_max_file_size), Enum.join(ExTus.Config.extensions, ",")})}]")
    conn
    |> handle_preflight_request
    |> put_resp_header("Tus-Resumable", ExTus.Config.tus_api_version)
    |> put_resp_header("Tus-Version", ExTus.Config.tus_api_version_supported)
    |> put_resp_header("Tus-Checksum-Algorithm", "sha1")
    |> put_resp_header("Tus-Max-Size", to_string(ExTus.Config.tus_max_file_size))
    |> put_resp_header("Tus-Extension", Enum.join(ExTus.Config.extensions, ","))
    |> resp(200, "")
  end

  def head(conn, identifier)do
    upload_info = UploadCache.get(identifier)
    if is_nil(upload_info) do
      Logger.error("[TUS][HEAD_ERROR: #{inspect(upload_info)}][NOT_FOUND]")
      conn
      |> Utils.set_base_resp
      |> resp(404, "Not Found! #{inspect(identifier)}")

    else
      upload_meta =
        %{
          size: upload_info.size,
          filename: upload_info.filename
        }

      upload_meta =
        upload_meta
        |> Enum.map(fn{k, v} ->  "#{k} #{Base.encode64(to_string(v))}" end)
        |> Enum.join(",")

      Logger.info("[TUS][HEAD: #{inspect(upload_meta)}]")
      
      if upload_meta not in ["", nil] do
        put_resp_header(conn, "Upload-Metadata", upload_meta)
      else
        conn
      end
      |> Utils.set_base_resp
      |> Utils.put_cors_headers
      |> put_resp_header("Upload-Offset", "#{upload_info.offset}")
      |> put_resp_header("Upload-Length", "#{upload_info.size}")
      |> resp(200, "Tus Head, returned upload_info: #{inspect(identifier)}")
    end
  end

  def patch(conn, identifier, complete_cb)do
    headers = Utils.read_headers(conn)
    {offset, _} = Integer.parse(headers["upload-offset"])
    upload_info = UploadCache.get(identifier)

    [alg, checksum] = String.split(headers["upload-checksum"] || "_ _")
    if headers["upload-checksum"] not in [nil, ""] and alg not in ExTus.Config.hash_algorithms do
      Logger.error("[TUS][UPLOAD_OFFSET_ERROR: Upload Checksum Null][HEADERS: #{inspect(headers)}]")
      conn
      |> Utils.set_base_resp
      |> resp(400, "Bad Request")
    else

      #%{size: current_offset} = File.stat!(file_path)
      if  offset != upload_info.offset do
        Logger.error("[TUS][UPLOAD_OFFSET_ERROR: #{inspect({offset, upload_info})}]")
        conn
        |> Utils.set_base_resp
        |> resp(409, "Conflict")
      else
        #read data Max chunk size is 8MB, if transferred data > 8MB, ignore it
        case read_body(conn) do
          {_, binary, conn} ->
            data_length = byte_size(binary)
            upload_info = Map.put(upload_info, :offset, data_length + upload_info.offset)

            # check Checksum if received a checksum digest
            if alg in ExTus.Config.hash_algorithms do
              alg = if alg == "sha1", do: "sha", else: alg
              hash_val = :crypto.hash(String.to_atom(alg), binary)
                |> Base.encode32()

              if checksum != hash_val do
                Logger.error("[TUS][PATCH_CHECKSUM_ERROR: #{inspect({checksum, hash_val})}]")
                conn
                |> Utils.set_base_resp
                |> resp(460, "Checksum Mismatch")

              else
                write_append_data(conn, upload_info, binary, complete_cb)
              end
            else
              write_append_data(conn, upload_info, binary, complete_cb)
            end
          
          {:error, term} ->
            error_str = inspect({upload_info, term})
            Logger.error("[TUS][PATCH_ERROR: #{error_str}]")
            conn
            |> Utils.set_base_resp
            |> resp(500, "Tus Patch Error: #{error_str}")
        end
      end

    end
  end

  defp write_append_data(conn, upload_info, binary, complete_cb) do
    storage().append_data(upload_info, binary)
    |> case do
      {:ok, upload_info} ->
        UploadCache.update(upload_info)
        
        Logger.info("[TUS][WRITE_APPEND_DATA: INFO: #{inspect(upload_info)}]")
        url =
        if upload_info.offset >= upload_info.size do
          rs = storage().complete_file(upload_info)

          # if upload fail remove uploaded file
          with {:error, err} <- rs do
            Logger.warn("[TUS][WRITE_APPEND_COMPLETION_ERROR: #{inspect({upload_info, err})}]")
            storage().abort_upload(upload_info)
          end

          # remove cache info
          UploadCache.delete(upload_info.identifier)

          if not is_nil(complete_cb) do
            complete_cb.(upload_info)
          else
            ""
          end
        else
          ""
        end

        conn
        |> Utils.set_base_resp
        |> Utils.put_cors_headers
        |> put_resp_header("Upload-Offset", "#{upload_info.offset}")
        |> put_resp_header("URL", "#{url}")
        |> resp(204, "")

      {:error, err} ->
        error_str = inspect({upload_info, err})
        Logger.error("[TUS][WRITE_APPEND_ERROR: #{error_str}]")
        conn
        |> Utils.set_base_resp
        |> resp(404, "Tus Error in Write Append Data: #{error_str}")
    end
  end

  def post(conn, create_cb)do
     headers = Utils.read_headers(conn)

     upload_type = headers["upload-type"]
     meta = Utils.parse_meta_data(headers["upload-metadata"])
     {upload_length, _} = Integer.parse(headers["upload-length"])

     if upload_length > ExTus.Config.tus_max_file_size do
       conn
       |> resp(413, "Tus Max File Size Exceeded: #{upload_length}")
     else
       file_name =
         (meta["filename"] || "")
         |> Base.decode64!

       {:ok, {identifier, filename}} = storage().initiate_file(file_name)

       info = %UploadInfo{
         identifier: identifier,
         filename: filename,
         size: upload_length,
         started_at: DateTime.utc_now |> DateTime.to_iso8601
       }
       UploadCache.put(info)

       if create_cb do
         create_cb.(info)
       end

       location = get_upload_location(conn, upload_type, identifier)

       conn
       |> put_resp_header("Tus-Resumable", ExTus.Config.tus_api_version)
       |> put_resp_header("Location", location)
       |> Utils.put_cors_headers
       |> resp(201, "")
     end
  end


  def delete(conn, identifier) do
    upload_info = UploadCache.get(identifier)

    if is_nil(upload_info) do
      conn
      |> Utils.set_base_resp
      |> resp(404, "Not Found")
    else
      case storage().delete(upload_info) do
        :ok ->
          conn
          |> Utils.set_base_resp
          |> Utils.put_cors_headers
          |> resp(204, "No Content")
        _ ->
          conn
          |> Utils.set_base_resp
          |> resp(500, "Server Error")
      end
    end
  end

  def handle_preflight_request(conn) do
    headers = Enum.into(conn.req_headers, Map.new)
    if headers["access-control-request-method"] do
      conn
      |> put_resp_header("Access-Control-Allow-Methods", "POST, GET, HEAD, PATCH, DELETE, OPTIONS")
      |> put_resp_header("Access-Control-Allow-Headers", "Origin, X-Requested-With, Content-Type, Upload-Length, Upload-Offset, Tus-Resumable, Upload-Metadata")
      |> put_resp_header("Access-Control-Max-Age", "86400")
    else
      conn
    end
  end

  def get_upload_location(conn, upload_type, identifier) do
    base_url =
    case Application.get_env(:extus, :environment) do
      :prod ->
        scheme = :https
        ("#{scheme}://#{conn.host }")
      _ ->
        scheme = :https
        ("#{scheme}://#{conn.host }")
    end

    Logger.info("[TUS][POST][GET_UPLOAD_LOCATION][UPLOAD_TYPE: #{inspect(upload_type)}][IDENTIFIER: #{inspect(identifier)}][ENV: #{inspect(Application.get_env(:extus, :environment))}][BASE_URL: #{inspect(base_url)}]")

    base_url
          |> URI.merge(Path.join(
          case upload_type do
            "VIDEO_ANSWER" -> ExTus.Config.video_upload_url
            _ -> ExTus.Config.upload_url
          end,
          identifier))
          |> to_string
  end
end
