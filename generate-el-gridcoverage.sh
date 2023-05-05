#!/usr/bin/env bash
# 
# Bash script to generate ElevationGridCoverage GML according to the INSPIRE elevation data theme
# see https://inspire.ec.europa.eu/Themes/118/2892
# script dependencies
# - gdal-bin
# - jq: https://stedolan.github.io/jq/manual/
# - jinja-cli: https://pypi.org/project/jinja-cli/
# - exiftool
#
# author: https://github.com/arbakker/
#
# Usage: Generates ElevationGridCoverage GML based on Geotiffs stored in ./data/ directory in the root of this repository. 
#

set -euo pipefail


tif_dir="./data"

output_json=$(mktemp --suffix=".json" )

for file in $tif_dir/*.tif;do
    filename=$(basename $file)
    filename_no_ext=${filename%.*}

    gdalinfo=$(gdalinfo -json -stats "$file")
    nodata_val=$(jq ".bands[0].noDataValue" <<< "$gdalinfo")
    min_val=$(jq ".bands[0].minimum" <<< "$gdalinfo")
    max_val=$(jq ".bands[0].maximum" <<< "$gdalinfo")

    size_x=$(jq ".size[0]" <<< "$gdalinfo")
    size_y=$(jq ".size[1]" <<< "$gdalinfo")
    epsg_code=$(gdalsrsinfo -e $file |  grep "EPSG:" | cut -d":" -f2)

    pixelsize_x=$(jq ".geoTransform[1]" <<< "$gdalinfo")
    pixelsize_y=$(jq ".geoTransform[5]" <<< "$gdalinfo")

    origin_x=$(jq ".geoTransform[0]" <<< "$gdalinfo")
    origin_y=$(jq ".geoTransform[3]" <<< "$gdalinfo")
  
    ll_x=$(jq '.cornerCoordinates.lowerLeft[0]' <<< "$gdalinfo")
    ll_y=$(jq '.cornerCoordinates.lowerLeft[1]' <<< "$gdalinfo")
    ur_x=$(jq '.cornerCoordinates.upperRight[0]' <<< "$gdalinfo")
    ur_y=$(jq '.cornerCoordinates.upperRight[1]' <<< "$gdalinfo")

    extent_ring="${ll_y} ${ll_x} ${ll_y} ${ur_x} ${ur_y} ${ur_x} ${ur_y} ${ll_x} ${ll_y} ${ll_x}"

    planar_configuration=$(exiftool "$file" | grep "Planar"| cut -d":" -f2 | xargs)


    jq -n \
    --arg filename "$filename" \
    --arg filename_no_ext "$filename_no_ext" \
    --argjson epsg_code "$epsg_code" \
    --argjson size_x "$size_x" \
    --argjson size_y "$size_y" \
    --argjson pixelsize_x "$pixelsize_x" \
    --argjson pixelsize_y "$pixelsize_y" \
    --argjson origin_y "$origin_y" \
    --argjson origin_x "$origin_x" \
    --arg planar_configuration "$planar_configuration" \
    --argjson min_val "$min_val" \
    --argjson max_val "$max_val" \
    --argjson nodata_val "$nodata_val" \
    --arg extent_ring "$extent_ring" \
    '{
        "filename": $filename,
        "id": $filename_no_ext,
        "epsgCode": $epsg_code,
        "sizeX": $size_x,
        "sizeY": $size_y,
        "pixelsizeX": $pixelsize_x,
        "pixelsizeY": $pixelsize_y,
        "originX": $origin_x,
        "originY": $origin_y,
        "planarConfiguration": $planar_configuration,
        "minVal": $min_val,
        "maxVal": $max_val,
        "extentRing": $extent_ring,
        "nodataVal": $nodata_val
    }' 
done |  jq -s '{"grids": .}' > "$output_json"

gml=$(jinja -d "$output_json" "el.gridcoverage.template.xml")


# generate bbox for gml
IFS=$'\t' read -r ll_x ll_y ur_x ur_y < <(
    echo "$gml" | ogrinfo -so  /vsistdin/ ElevationGridCoverage | grep Extent: | sed -r 's|^Extent:\s\(([0-9]+\.[0-9]+),\s([0-9]+\.[0-9]+)\)\s-\s\(([0-9]+\.[0-9]+),\s([0-9]+\.[0-9]+)\)$|\1\t\2\t\3\t\4|'
)
epsg_code=$(jq '.grids[0].epsgCode' < "$output_json")
output_bbox_json=$(mktemp --suffix=".json" )

jq -n \
    --argjson ll_x "$ll_x" \
    --argjson ll_y "$ll_y" \
    --argjson ur_x "$ur_x" \
    --argjson ur_y "$ur_y" \
    --argjson epsg_code "$epsg_code" \
    '{
        "llX": $ll_x,
        "llY": $ll_y,
        "urX": $ur_x,
        "urY": $ur_y,
        "epsgCode": $epsg_code
    }' > "$output_bbox_json"
gml_bbox=$(jinja -d "$output_bbox_json" "bbox.template.xml")


# insert gml_bbox in gml before first featureMember
line_insert_before=$(grep -n "<gml:featureMember>" <<< "$gml" | head -n1 | cut -d: -f1)
head -n $((line_insert_before-1))  <<< "$gml" && echo "$gml_bbox" && tail -n +$((line_insert_before-1)) <<< "$gml"
