# Copyright 2026 Esri
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

defmodule ArcGIS.Feature.Service do
  @moduledoc """
  Feature service acccess.

  For fetching data from a feature service, see `ArcGIS.Feature`.
  """

  alias __MODULE__.CreateParameters
  alias ArcGIS.Portal
  alias ArcGIS.Telemetry

  @cache_name :feature_service_urls

  @enforce_keys [:id]
  defstruct [:portal, :id, :schema]

  @typedoc """
  Definition of a feature service including the Portal it is hosted on and the Feature Service's ID
  """

  @type t() :: %__MODULE__{
          portal: Portal.t(),
          id: String.t(),
          schema: nil | ArcGIS.Feature.Schema.t()
        }

  @spec create(Portal.t(), CreateParameters.t(), options :: Portal.portal_options()) ::
          {:ok, t()} | {:error, reason :: String.t()}
  def create(%Portal{} = portal, %CreateParameters{} = parameters, options) do
    # TODO: support the following? tags, snippet, overwrite, isView
    owner =
      cond do
        is_binary(parameters.owner) ->
          parameters.owner

        is_binary(Keyword.get(options, :auth_token)) ->
          {:ok, user} = ArcGIS.User.from_token(portal, Keyword.get(options, :auth_token))
          user.name.user
      end

    default_params = %{"supportedQueryFormats" => "JSON", "owner" => owner}

    params =
      Enum.reduce(Map.from_struct(parameters), default_params, &generate_create_document/2)
      |> :json.encode()
      |> to_string()

    form_data = %{"outputType" => "featureService", "createParameters" => params}

    folder =
      case parameters.folder_id do
        nil -> ""
        id -> "/#{id}"
      end

    resource = "/content/users/#{owner}#{folder}/createService"

    case Portal.post(portal, resource, form_data, options) do
      {:ok, %{"itemId" => id, "serviceurl" => url}} ->
        service = %__MODULE__{portal: portal, id: id}
        cache(service, url)
        {:ok, service}

      {:error, _} = error ->
        error

      other_error ->
        Telemetry.handle_error(other_error)
    end
  end

  @spec get(t(), resource :: String.t(), options :: Portal.portal_options()) ::
          {:ok, map} | {:error, reason :: String.t()}
  @doc """
  Sends a GET request to a feature service.

  The resource is path fragment for the rquest (e.g. `/applyEdits`).

  Authentication tokens, etc. can be passed in via the options parameter.
  """
  def get(%__MODULE__{} = service, resource, options \\ []) do
    case resource_url(service, resource, options) do
      {:error, _} = error -> error
      url -> Portal.get(service.portal, url, options)
    end
  end

  @spec post(t(), resource :: String.t(), form_data :: map, options :: Portal.portal_options()) ::
          {:ok, map} | {:error, reason :: String.t()}
  @doc """
  Sends a POST request to a feature service.

  The resource is path fragment for the rquest (e.g. `/applyEdits`).

  Authentication tokens, etc. can be passed in via the options parameter.
  """
  def post(%__MODULE__{} = service, resource, form_data, options \\ []) do
    case resource_url(service, resource, options) do
      {:error, _} = error -> error
      resource -> Portal.post(service.portal, resource, form_data, options)
    end
  end

  @spec url(t()) :: String.t()
  @doc """
  Returns the access URL for a feature service.
  """
  def url(%__MODULE__{} = service, options \\ []) do
    case Cachex.get(@cache_name, cache_key(service)) do
      {:ok, url} when url != nil ->
        Telemetry.handle_success(%Telemetry{measurements: %{service_cache_hit: 1}})
        {:ok, url}

      _ ->
        fetch_and_cache_url(service, options)
    end
  end

  @doc """
  Fetches the schema for a feature servcie and on success assigned it to the
  `schema` field of the `Service.t()`
  """
  @spec with_schema(t(), options :: Portal.portal_options()) :: t()
  def with_schema(service, options \\ [])

  def with_schema(%__MODULE__{schema: nil} = service, options) do
    case ArcGIS.Feature.Schema.get(service, options) do
      {:ok, schema} -> %{service | schema: schema}
      _ -> service
    end
  end

  def with_schema(service, _options), do: service

  @spec fetch_and_cache_url(t(), options :: Portal.portal_options()) ::
          {:ok, String.t()} | {:error, term}
  defp fetch_and_cache_url(service, options) do
    options = [
      auth_token: Keyword.get(options, :auth_token, ""),
      verify_tls: Keyword.get(options, :verify_tls)
    ]

    case Portal.Item.get(service.portal, service.id, options) do
      {:ok, %{url: url}} ->
        result = cache(service, url)
        {:ok, result}

      error ->
        error
    end
  end

  @spec cache(t(), url :: String.t()) :: URI.t()
  defp cache(service, url) do
    uri = URI.parse(url)
    Cachex.put(@cache_name, cache_key(service), uri)
    uri
  end

  @spec cache_key(t()) :: String.t()
  defp cache_key(%__MODULE__{portal: %{base_url: url}, id: id}) do
    id <> "@" <> url.host
  end

  defp resource_url(service, resource, options) do
    case url(service, options) do
      {:ok, url} ->
        if resource != nil do
          URI.append_path(url, resource)
        else
          url
        end

      error ->
        error
    end
  end

  defp generate_create_document({_, nil}, acc), do: acc
  defp generate_create_document({:capabilities, []}, acc), do: acc

  defp generate_create_document({:capabilities = key, capabilities}, acc) do
    capabilities_string = Enum.map_join(capabilities, ",", &Inflex.camelize/1)
    Map.put(acc, Inflex.camelize(key, :lower), capabilities_string)
  end

  defp generate_create_document({:editor_tracking, true}, acc) do
    value = %{
      enableEditorTracking: true
    }

    Map.put(acc, "editorTrackingInfo", value)
  end

  defp generate_create_document({:editor_tracking, _}, acc), do: acc

  defp generate_create_document({key, value}, acc)
       when key in [
              :allow_geometry_updates,
              :description,
              :has_static_data,
              :max_record_count,
              :name,
              :owner,
              :service_description
            ] do
    Map.put(acc, Inflex.camelize(key, :lower), value)
  end

  defp generate_create_document(_, acc), do: acc
end
