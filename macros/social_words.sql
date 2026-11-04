{#
  Word matching and word merging for the social board's "Driven by" line
  (int_social_board_drivers) and its rising-words list (mart_social_rising_words). Both
  read the words found inside post text (int_social_post_words), both map posts to board
  rows the way the board does (social_post_products), and both must merge the ways one
  story gets written as several words — so all of that lives here, once.
  See models/docs/_social_windows.md, section 10.
#}


{# A Latin word must match as a WHOLE word: "tea" is not in "steak", "pie" is not in
   "pierce". Thai has no spaces between words, so Thai words match as plain substrings
   (the caller only applies this to Latin words). RE2 (duckdb) has no lookbehind, so the
   boundary is spelled with alternations; \Q..\E makes the word literal on both engines.
   databricks reads '\\' in a string literal as one backslash, duckdb reads it as two. #}
{% macro whole_word_match(text, term) -%}
    {{ return(adapter.dispatch('whole_word_match', 'ust_digital_platform')(text, term)) }}
{%- endmacro %}

{% macro default__whole_word_match(text, term) -%}
    regexp_matches({{ text }}, '(^|[^a-z0-9])\Q' || {{ term }} || '\E([^a-z0-9]|$)')
{%- endmacro %}

{% macro databricks__whole_word_match(text, term) -%}
    ({{ text }} rlike concat('(^|[^a-z0-9])\\Q', {{ term }}, '\\E([^a-z0-9]|$)'))
{%- endmacro %}

{% macro spark__whole_word_match(text, term) -%}
    ({{ text }} rlike concat('(^|[^a-z0-9])\\Q', {{ term }}, '\\E([^a-z0-9]|$)'))
{%- endmacro %}


{# Integers start..stop as an array, to unnest() into one row each.
   duckdb generate_series, databricks sequence. Keep stop >= start: databricks counts
   DOWN when stop < start, duckdb returns nothing. #}
{% macro int_series(start, stop) -%}
    {{ return(adapter.dispatch('int_series', 'ust_digital_platform')(start, stop)) }}
{%- endmacro %}

{% macro default__int_series(start, stop) -%}
    generate_series({{ start }}, {{ stop }})
{%- endmacro %}

{% macro databricks__int_series(start, stop) -%}
    sequence({{ start }}, {{ stop }})
{%- endmacro %}

{% macro spark__int_series(start, stop) -%}
    sequence({{ start }}, {{ stop }})
{%- endmacro %}


{# helpers: "a.week_start = b.week_start and a.concept_class = ..." and "a.week_start, a.concept_class" #}
{% macro _sw_on(a, b, cols) -%}
    {%- for c in cols %}{{ a }}.{{ c }} = {{ b }}.{{ c }}{% if not loop.last %} and {% endif %}{% endfor -%}
{%- endmacro %}

{% macro _sw_cols(alias, cols) -%}
    {%- for c in cols %}{{ alias }}.{{ c }}{% if not loop.last %}, {% endif %}{% endfor -%}
{%- endmacro %}


{#
  social_post_products — a select of every post's tags mapped to the PRODUCT key the board
  counts it under: one row per (mention, product, spelling). The driver line and the
  rising list both read it, so it is written once here rather than as a model.

  MIRRORS int_social_concept_trends.grouped — the name map (int_social_concept_canon)
  then the resolver's grouping (group_primary) — so a board row's posts here are the
  posts the board counted. Keep the two in step: if the board's mapping changes, this
  must change with it, or "12 of 25 posts" stops meaning the row's 25.

  term is the spelling the post used (lower-cased), which is what tells the driver line
  which words ARE the row (its own spellings are not what drives it).
#}
{% macro social_post_products() -%}
    select distinct
        cm.mention_id,
        cast(f.posted_week as date)                                     as week_start,
        coalesce(cn.product_class, cm.concept_class)                    as concept_class,
        coalesce(g.group_primary, cn.product_key, cm.concept_norm)      as concept_norm,
        lower(trim(cm.concept_text))                                    as term
    from {{ ref('int_social_concept_mentions') }} as cm
    inner join {{ ref('fct_social_mentions') }} as f
        on f.mention_id = cm.mention_id
    left join {{ ref('int_social_concept_canon') }} as cn
        on  cn.concept_class = cm.concept_class
        and cn.concept_norm  = cm.concept_norm
    left join (
        select concept_norm, group_primary
        from {{ ref('stg_mentionlytics__concept_resolution') }}
        where group_primary is not null
    ) as g
        on g.concept_norm = coalesce(cn.product_key, cm.concept_norm)
{%- endmacro %}


{#
  social_driver_rows — the steps every "Driven by" model starts from, emitted as CTEs
  (no leading `with`, no trailing comma):
    board          the week's board rows, and each row's name
    hits           the words found in post text (int_social_post_words)
    post_products  every post's board product (social_post_products)
    row_posts      each board row's posts: this week (is_now) and the base_weeks before
    row_size       how many posts each row has, this week and before
    row_hits       the words in each row's posts
  int_social_driver_words, int_social_driver_stories and int_social_board_drivers all
  need them; written once here.
#}
{% macro social_driver_rows(base_weeks) -%}
board as (

    select
        week_start,
        concept_class,
        concept_norm,
        lower(coalesce(product_name, concept_norm))                     as row_name
    from {{ ref('int_social_trend_board') }}
    where is_on_board

),

hits as (

    select mention_id, week_start, owner, term
    from {{ ref('int_social_post_words') }}
    where term is not null

),

-- every post's board product, mapped exactly as the board maps it
post_products as (

    {{ social_post_products() }}

),

-- each board row's posts: this week (is_now) and the baseline weeks before it
row_posts as (

    select distinct
        b.week_start,
        b.concept_class,
        b.concept_norm,
        pp.mention_id,
        pp.week_start = b.week_start                                    as is_now
    from board as b
    inner join post_products as pp
        on  pp.concept_class = b.concept_class
        and pp.concept_norm  = b.concept_norm
        and pp.week_start between cast({{ dbt.dateadd('day', -7 * base_weeks, 'b.week_start') }} as date)
                              and b.week_start

),

row_size as (

    select
        week_start,
        concept_class,
        concept_norm,
        count(distinct case when is_now then mention_id end)            as row_posts,
        count(distinct case when not is_now then mention_id end)        as row_before
    from row_posts
    group by 1, 2, 3

),

row_hits as (

    select rp.week_start, rp.concept_class, rp.concept_norm, rp.is_now, pw.term, pw.mention_id, pw.owner
    from row_posts as rp
    inner join hits as pw
        on pw.mention_id = rp.mention_id

)
{%- endmacro %}


{#
  WORDS -> GROUPS -> STORIES, inside each partition (a board row for the driver line, a
  week for the Rising list). Two macros, because each feature saves the groups as a TABLE
  between them: as one query, the steps below reuse each other so often that Databricks
  could not finish compiling it (2026-11-04: the driver query expanded to ~415,000 step
  evaluations; every model that compiles fine there is under ~500). Split at the groups,
  each query stays small and the rows are the same.

  SPELLINGS (social_word_groups). สกุชชี่ / สกุชชี่เค้ก / เค้กสกุชชี่ are one word. A longer
    word folds into a shorter word it contains when the shorter one is at least half its
    length (สกุชชี่ -> สกุชชี่เค้ก, but coconut does not swallow "mango coconut sticky rice")
    and it is the ONLY such word: ต้มโคล้งต้นหอม contains two different words, so it is a
    combination, not a spelling, and joins neither. Two hops of parents cover real
    spellings.

  STORIES (social_word_stories). A group is shown by its most-posted spelling, or by a
    longer spelling of it that carries 40%+ of that one's posts (สกุชชี่เค้ก reads better
    than สกุชชี่ and is the same thing). Different words that ride on the same posts are one
    story (the Starbucks holiday menu: mocha, reindeer brookie, oat milk ... in the same
    nine posts). A group joins the BIGGEST group it shares at least `overlap` of the
    smaller one's posts with, when that group is bigger; two hops. Inside a story, a word
    that is part of another word is only its general form (มาม่า beside มาม่าเกาหลี) and
    is not shown.

  Inputs and outputs (CTE or relation names; macros emit CTEs, no leading `with`, no
  trailing comma):
    social_word_groups(cands, ...)            cands: partition..., term, n_posts
      -> {prefix}_grp       partition..., term, n_posts, grp      every candidate -> its group
    social_word_group_hits(groups, hits, ...) hits: partition..., term, post_key
      -> {prefix}_grp_hits  partition..., grp, post_key           a group's posts
    social_word_stories(groups, hits, ...)    groups: partition..., term, n_posts, grp
      -> {prefix}_grp_hits as above, and
         {prefix}_story     partition..., grp, head, grp_posts, also_written, story
                            one row per group SHOWN in a story (general forms already dropped)
  Every "drop X when Y" is a left-join anti-join, not a correlated subquery: databricks
  restricts non-equality predicates in correlated subqueries, a join it never refuses.
#}
{% macro social_word_groups(cands, partition, prefix) -%}
{%- set p = partition -%}
{{ prefix }}_contains as (

    -- x sits inside y and is at least half y's length: x is a candidate root of y
    select {{ _sw_cols('y', p) }}, y.term, x.term as root
    from {{ cands }} as x
    inner join {{ cands }} as y
        on  {{ _sw_on('x', 'y', p) }}
        and x.term <> y.term
        and instr(y.term, x.term) > 0
        and length(x.term) * 2 >= length(y.term)

),

{{ prefix }}_inner_root as (

    -- a root that is itself inside another root of the same word is not maximal
    select distinct {{ _sw_cols('c', p) }}, c.term, c.root
    from {{ prefix }}_contains as c
    inner join {{ prefix }}_contains as c2
        on  {{ _sw_on('c2', 'c', p) }}
        and c2.term = c.term
        and c2.root <> c.root
        and instr(c2.root, c.root) > 0

),

{{ prefix }}_parent as (

    -- exactly ONE maximal root makes a spelling; two different ones make a combination
    select {{ _sw_cols('c', p) }}, c.term, min(c.root) as parent
    from {{ prefix }}_contains as c
    left join {{ prefix }}_inner_root as i
        on  {{ _sw_on('i', 'c', p) }}
        and i.term = c.term
        and i.root = c.root
    where i.root is null
    group by {{ _sw_cols('c', p) }}, c.term
    having count(*) = 1

),

{{ prefix }}_grp as (

    select
        {{ _sw_cols('c', p) }},
        c.term,
        c.n_posts,
        coalesce(p2.parent, p1.parent, c.term)                          as grp
    from {{ cands }} as c
    left join {{ prefix }}_parent as p1
        on {{ _sw_on('p1', 'c', p) }} and p1.term = c.term
    left join {{ prefix }}_parent as p2
        on {{ _sw_on('p2', 'c', p) }} and p2.term = p1.parent

)
{%- endmacro %}


{% macro social_word_group_hits(groups, hits, partition, prefix) -%}
{%- set p = partition -%}
{{ prefix }}_grp_hits as (

    select distinct {{ _sw_cols('g', p) }}, g.grp, h.post_key
    from {{ groups }} as g
    inner join {{ hits }} as h
        on {{ _sw_on('h', 'g', p) }} and h.term = g.term

)
{%- endmacro %}


{% macro social_word_stories(groups, hits, partition, prefix, overlap) -%}
{%- set p = partition -%}
{{ social_word_group_hits(groups, hits, partition, prefix) }},

{{ prefix }}_grp_posts as (

    select {{ p | join(', ') }}, grp, count(*) as grp_posts
    from {{ prefix }}_grp_hits
    group by {{ p | join(', ') }}, grp

),

{{ prefix }}_ranked as (

    select
        g.*,
        row_number() over (
            partition by {{ _sw_cols('g', p) }}, g.grp
            order by g.n_posts desc, length(g.term), g.term
        )                                                               as rn
    from {{ groups }} as g

),

{{ prefix }}_longer as (

    -- a longer spelling of the top one, carrying 40%+ of its posts, reads better
    select
        {{ _sw_cols('r', p) }},
        r.grp,
        r.term,
        row_number() over (
            partition by {{ _sw_cols('r', p) }}, r.grp
            order by r.n_posts desc, length(r.term) desc, r.term
        )                                                               as rn
    from {{ prefix }}_ranked as r
    inner join {{ prefix }}_ranked as t
        on {{ _sw_on('t', 'r', p) }} and t.grp = r.grp and t.rn = 1
    where r.term <> t.term
      and instr(r.term, t.term) > 0
      and r.n_posts >= 0.4 * t.n_posts

),

{{ prefix }}_head as (

    select
        {{ _sw_cols('t', p) }},
        t.grp,
        coalesce(l.term, t.term)                                        as head,
        gp.grp_posts
    from {{ prefix }}_ranked as t
    left join {{ prefix }}_longer as l
        on {{ _sw_on('l', 't', p) }} and l.grp = t.grp and l.rn = 1
    inner join {{ prefix }}_grp_posts as gp
        on {{ _sw_on('gp', 't', p) }} and gp.grp = t.grp
    where t.rn = 1

),

{{ prefix }}_also as (

    -- the group's other spellings, most posted first (three are plenty to recognise it)
    select
        {{ _sw_cols('r', p) }},
        r.grp,
        nullif(concat_ws(', ',
            max(case when r.k = 1 then r.term end),
            max(case when r.k = 2 then r.term end),
            max(case when r.k = 3 then r.term end)), '')                as also_written
    from (
        select
            g.*,
            row_number() over (
                partition by {{ _sw_cols('g', p) }}, g.grp order by g.n_posts desc, g.term
            )                                                           as k
        from {{ groups }} as g
        inner join {{ prefix }}_head as h
            on {{ _sw_on('h', 'g', p) }} and h.grp = g.grp
        where g.term <> h.head
    ) as r
    group by {{ _sw_cols('r', p) }}, r.grp

),

{{ prefix }}_shared as (

    select {{ _sw_cols('a', p) }}, a.grp as grp_a, b.grp as grp_b, count(*) as shared
    from {{ prefix }}_grp_hits as a
    inner join {{ prefix }}_grp_hits as b
        on  {{ _sw_on('a', 'b', p) }}
        and a.post_key = b.post_key
        and a.grp <> b.grp
    group by {{ _sw_cols('a', p) }}, a.grp, b.grp

),

{{ prefix }}_attach as (

    -- each group joins the biggest group it rides with, when that one is bigger
    select
        {{ _sw_cols('s', p) }},
        s.grp_a                                                         as grp,
        s.grp_b                                                         as to_grp,
        row_number() over (
            partition by {{ _sw_cols('s', p) }}, s.grp_a
            order by hb.grp_posts desc, s.grp_b
        )                                                               as rn
    from {{ prefix }}_shared as s
    inner join {{ prefix }}_head as ha
        on {{ _sw_on('ha', 's', p) }} and ha.grp = s.grp_a
    inner join {{ prefix }}_head as hb
        on {{ _sw_on('hb', 's', p) }} and hb.grp = s.grp_b
    where s.shared >= {{ overlap }} * least(ha.grp_posts, hb.grp_posts)
      and (hb.grp_posts > ha.grp_posts or (hb.grp_posts = ha.grp_posts and s.grp_b < s.grp_a))

),

{{ prefix }}_story_all as (

    select
        {{ _sw_cols('h', p) }},
        h.grp,
        h.head,
        h.grp_posts,
        coalesce(a2.to_grp, a1.to_grp, h.grp)                           as story
    from {{ prefix }}_head as h
    left join {{ prefix }}_attach as a1
        on {{ _sw_on('a1', 'h', p) }} and a1.grp = h.grp and a1.rn = 1
    left join {{ prefix }}_attach as a2
        on {{ _sw_on('a2', 'h', p) }} and a2.grp = a1.to_grp and a2.rn = 1

),

{{ prefix }}_general as (

    -- inside one story, a word that is part of another word is its general form
    select distinct {{ _sw_cols('s', p) }}, s.grp
    from {{ prefix }}_story_all as s
    inner join {{ prefix }}_story_all as s2
        on  {{ _sw_on('s2', 's', p) }}
        and s2.story = s.story
        and s2.grp <> s.grp
        and instr(s2.head, s.head) > 0

),

{{ prefix }}_story as (

    select s.*, al.also_written
    from {{ prefix }}_story_all as s
    left join {{ prefix }}_general as gen
        on {{ _sw_on('gen', 's', p) }} and gen.grp = s.grp
    left join {{ prefix }}_also as al
        on {{ _sw_on('al', 's', p) }} and al.grp = s.grp
    where gen.grp is null

)
{%- endmacro %}
