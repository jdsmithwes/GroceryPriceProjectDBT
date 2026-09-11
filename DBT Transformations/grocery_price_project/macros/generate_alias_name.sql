{#
    Project-wide convention (2026-09-11): every dbt-built object (models
    AND seeds — both resolve their Snowflake identifier through this same
    macro) gets a DBT_ prefix, distinguishing dbt output from hand-built
    objects that live in the same database (e.g. the Kroger/Walmart raw
    landing tables in GROCERY_RAW_KROGER/GROCERY_RAW_WALMART, which are
    created directly via SQL DDL + Snowpipe, not by dbt).

    Before this macro existed, someone renamed a handful of objects to
    DBT_* directly in Snowflake to get this same effect — but a manual
    rename doesn't survive the next `dbt run`/`dbt seed`, since dbt has
    no record of it and just recreates the object under its default
    (unprefixed) name. This macro makes the convention durable.
#}
{% macro generate_alias_name(custom_alias_name=none, node=none) -%}
    {%- if custom_alias_name is none -%}
        DBT_{{ node.name }}
    {%- else -%}
        DBT_{{ custom_alias_name | trim }}
    {%- endif -%}
{%- endmacro %}
