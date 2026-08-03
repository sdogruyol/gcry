# Entry for Boehm / gcry A/B of vendored crystal-metric.
#
# boehm: crystal build --release main.cr -o ../../bin/crystal-metric-boehm
# gcry:  crystal build -Dgc_none --release main.cr -o ../../bin/crystal-metric-gcry
#
# Filter (class names): ./bin/crystal-metric-gcry Binarytrees,JsonGenerate

{% if flag?(:gc_none) %}
  require "gcry"
{% end %}

require "./metric"
