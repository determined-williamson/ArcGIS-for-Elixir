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

defmodule ArcGIS.Feature do
  @moduledoc """
  Access to features in an ArcGIS feature service.
  """

  alias ArcGIS.Feature.Service
  alias ArcGIS.Telemetry

  # TODO: define geometry properly
  @type feature_geometry :: map
  @typedoc "An ArcGIS feature made up of attributes and geometry"
  @type t :: %{attributes: %{[key :: String.t()] => term}, geometry: feature_geometry}
  @type features_by_id :: [non_neg_integer]
  @type features_by_global_id :: [String.t()]
  @type mutations :: %{
          optional(:create) => [t()],
          optional(:update) => [t()],
          optional(:delete) => [features_by_id] | [features_by_global_id]
        }
  @type mutations_by_layer_id :: %{non_neg_integer => mutations}

  @type upload_format :: :json | :pbf
  @type mutate_option ::
          {:rollback_on_failure, boolean}
          | {:upload_format, upload_format}
          | {:use_global_ids, boolean}

  @spec from_map(source :: map, metadata :: map) :: t()
  @doc "Create a new feature struct from a map of data, such as returned by ArcGIS"
  def from_map(%{"geometry" => geometry} = data, %{geometry_type: geometry_type} = metadata) do
    srid =
      metadata
      |> Map.get(:spatial_reference, %ArcGIS.SpatialReference{})
      |> ArcGIS.SpatialReference.best_srid()

    %{
      attributes: data["attributes"],
      geometry: as_geometry(geometry_type, geometry, srid)
    }
  end

  def from_map(data, _metadata), do: data

  @spec query(Service.t(), layer_id :: non_neg_integer(), [ArcGIS.Portal.request_option()]) ::
          {:ok, Portal.ResultSet.t()} | {:error, term()}
  @doc "Query features in a Feature Service layer or table"
  def query(%Service{} = feature_service, layer_id, options \\ [])
      when is_number(layer_id) and layer_id >= 0 do
    options =
      options
      |> Keyword.put(:transform, &__MODULE__.from_map/2)
      |> Keyword.put(:is_features_query?, true)

    Service.post(feature_service, "/#{layer_id}/query", [], options)
    |> normalize_results(feature_service, layer_id, options)
  end

  @spec mutate(
          Service.t(),
          mutations :: mutations_by_layer_id,
          options :: [Portal.request_option() | mutate_option]
        ) :: {:ok, map()} | {:error, term()}
  @doc "Add, update, and/or delete features from one or more layers. Defaults to rolling back on failure."
  def mutate(service, mutations, options \\ []) do
    service = Service.with_schema(service, options)

    document =
      Enum.map(
        mutations,
        fn {layer_id, edits} ->
          %{id: layer_id}
          |> add_create(edits, service)
          |> add_update(edits, service)
          |> add_delete(edits, service)
        end
      )
      |> :json.encode()
      |> to_string()

    params = %{
      useGlobalIds: Keyword.get(options, :use_global_ids, true),
      rollbackOnFailure: Keyword.get(options, :rollback_on_failure, true),
      uploadFormat: Keyword.get(options, :upload_format, :json)
    }

    options_with_params =
      options
      |> Keyword.put(:params, params)
      |> Keyword.put(:telemetry, %Telemetry{
        metadata: %{service: service, action: :mutate_features}
      })
      |> Keyword.put(:is_features_query?, true)

    # TODO: support PBF formats
    document = [edits: document]

    Service.post(service, "/applyEdits", document, options_with_params)
  end

  @spec sanitize(features :: [t()], layer_id :: non_neg_integer, service :: Service.t()) :: [t()]
  @doc "Conforms a list of features to ArcGIS requirements, making them appropriate for e.g. use in mutations"
  def sanitize(features, _layer_id, %Service{schema: nil}) do
    features
  end

  def sanitize(features, layer_id, %Service{schema: schema, portal: %{type: portal_type}}) do
    # TODO: domain support; add `domain` field to field_types
    field_types =
      Enum.find_value(
        schema,
        fn
          {_, %{id: ^layer_id, fields: fields}} -> fields
          _ -> false
        end
      )
      |> Enum.reduce(%{}, fn field, acc -> Map.put(acc, field.name, field.type) end)

    Enum.map(features, fn feature -> sanitize_feature(feature, field_types, portal_type) end)
  end

  defp sanitize_feature(%{attributes: attributes} = feature, field_types, portal_type) do
    %{feature | attributes: sanitize_attributes(attributes, field_types, portal_type)}
  end

  defp sanitize_feature(%{"attributes" => attributes} = feature, field_types, portal_type) do
    %{feature | "attributes" => sanitize_attributes(attributes, field_types, portal_type)}
  end

  defp sanitize_attributes(attributes, field_types, portal_type) do
    Enum.reduce(attributes, %{}, fn {key, value}, acc ->
      sanitize_attribute(key, value, field_types, portal_type, acc)
    end)
  end

  defp sanitize_attribute(key, value, field_types, portal_type, acc) when is_binary(key) do
    # TODO: check other types, e.g. dates, etc.
    value =
      case Map.get(field_types, to_string(key)) do
        "esriFieldTypeGlobalID" -> wrap_global_id(value, portal_type)
        _ -> value
      end

    Map.put(acc, String.downcase(key), value)
  end

  defp sanitize_attribute(key, value, _field_typess, _portal_type, acc) do
    Map.put(acc, key, value)
  end

  defp add_create(%{id: layer_id} = arcgis_mutation, mutations, service) do
    features =
      mutations
      |> Map.get(:create, [])
      |> sanitize(layer_id, service)

    Map.put(arcgis_mutation, :adds, features)
  end

  defp add_update(%{id: layer_id} = arcgis_mutation, mutations, service) do
    features =
      mutations
      |> Map.get(:updates, [])
      |> sanitize(layer_id, service)

    Map.put(arcgis_mutation, :updates, features)
  end

  defp add_delete(arcgis_mutation, mutations, _service) do
    Map.put(arcgis_mutation, :deletes, Map.get(mutations, :delete, []))
  end

  defp as_geometry(Geometry.Polygon, geometry, srid) do
    %Geometry.Polygon{rings: geometry["rings"], srid: srid}
  end

  defp as_geometry(Geometry.PolygonZ, geometry, srid) do
    %Geometry.PolygonZ{rings: geometry["rings"], srid: srid}
  end

  defp as_geometry(Geometry.PolygonM, geometry, srid) do
    %Geometry.PolygonM{rings: geometry["rings"], srid: srid}
  end

  defp as_geometry(Geometry.PolygonZM, geometry, srid) do
    %Geometry.PolygonZM{rings: geometry["rings"], srid: srid}
  end

  defp as_geometry(Geometry.MultiLineString, geometry, srid) do
    %Geometry.MultiLineString{line_strings: geometry["paths"], srid: srid}
  end

  defp as_geometry(Geometry.MultiLineStringZ, geometry, srid) do
    %Geometry.MultiLineStringZ{line_strings: geometry["paths"], srid: srid}
  end

  defp as_geometry(Geometry.MultiLineStringM, geometry, srid) do
    %Geometry.MultiLineStringM{line_strings: geometry["paths"], srid: srid}
  end

  defp as_geometry(Geometry.MultiLineStringZM, geometry, srid) do
    %Geometry.MultiLineStringZM{line_strings: geometry["paths"], srid: srid}
  end

  defp as_geometry(Geometry.MultiPoint, geometry, srid) do
    %Geometry.MultiPoint{points: geometry["points"], srid: srid}
  end

  defp as_geometry(Geometry.MultiPointZ, geometry, srid) do
    %Geometry.MultiPointZ{points: geometry["points"], srid: srid}
  end

  defp as_geometry(Geometry.MultiPointM, geometry, srid) do
    %Geometry.MultiPointM{points: geometry["points"], srid: srid}
  end

  defp as_geometry(Geometry.MultiPointZM, geometry, srid) do
    %Geometry.MultiPointZM{points: geometry["points"], srid: srid}
  end

  defp as_geometry(Geometry.PointZ, %{"x" => x, "y" => y, "z" => z}, srid) do
    Geometry.PointZ.new(x, y, z, srid)
  end

  defp as_geometry(Geometry.PointM, %{"x" => x, "y" => y, "m" => m}, srid) do
    Geometry.PointM.new(x, y, m, srid)
  end

  defp as_geometry(Geometry.PointZM, %{"x" => x, "y" => y, "z" => z, "m" => m}, srid) do
    Geometry.PointZM.new(x, y, z, m, srid)
  end

  defp as_geometry(Geometry.Point, %{"x" => x, "y" => y}, srid) do
    Geometry.Point.new(x, y, srid)
  end

  defp normalize_results(
         {:ok, %ArcGIS.Portal.ResultSet{} = result_set},
         feature_service,
         layer_id,
         options
       ) do
    {:ok,
     %{
       result_set
       | results: normalize_features(result_set.results, feature_service, layer_id, options)
     }}
  end

  defp normalize_results({:ok, _} = results, _feature_service, _layer_id, _options) do
    results
  end

  defp normalize_results(error, _feature_service, _layer_id, _options) do
    error
  end

  defp normalize_features(
         features,
         %Service{portal: %ArcGIS.Portal{type: :online}},
         _layer_id,
         _options
       ) do
    # ArcGIS Online provides results exactly as we would expect them,
    # so do nothing to the features
    features
  end

  defp normalize_features(features, %Service{schema: %{} = schema}, layer_id, _options) do
    global_id_fields = global_id_fields(schema, layer_id)
    Enum.map(features, fn feature -> normalize_feature(feature, global_id_fields) end)
  end

  defp normalize_features(features, service, layer_id, options) do
    # no schema, try to fetch one
    global_id_fields =
      case ArcGIS.Feature.Schema.get(service, options) do
        {:ok, schema} -> global_id_fields(schema, layer_id)
        _ -> ["GlobalID"]
      end

    Enum.map(features, fn feature -> normalize_feature(feature, global_id_fields) end)
  end

  defp normalize_feature(%{attributes: attrs} = feature, fields) do
    normalize_feature_attributes(feature, attrs, fields)
  end

  defp normalize_feature(%{"attributes" => attrs} = feature, fields) do
    feature
    |> Map.put(:attributes, attrs)
    |> Map.delete("attributes")
    |> normalize_feature_attributes(attrs, fields)
  end

  defp normalize_feature_attributes(feature, attrs, fields) do
    normalized_attrs =
      Enum.reduce(
        fields,
        attrs,
        fn field, attrs ->
          Map.replace_lazy(attrs, field, &unwrap_global_id/1)
        end
      )

    %{feature | attributes: normalized_attrs}
  end

  defp unwrap_global_id("{" <> rest) do
    String.slice(rest, 0, String.length(rest) - 1)
  end

  defp unwrap_global_id(id), do: id

  defp wrap_global_id(id, :online), do: id
  defp wrap_global_id("{" <> _ = id, _portal_type), do: id
  defp wrap_global_id(id, _portal_type), do: "{#{id}}"

  defp global_id_fields(schema, layer_id) do
    # extract the fields for the layer
    fields =
      Enum.find_value(
        schema,
        fn
          {_, %{id: ^layer_id, fields: fields}} -> fields
          _ -> false
        end
      )

    # return only global ID fields
    Enum.reduce(fields || [], [], fn
      %ArcGIS.Feature.Schema.Field{name: name, type: "esriFieldTypeGlobalID"}, acc -> [name | acc]
      _, acc -> acc
    end)
  end
end
