{{ config(tags=['social']) }}
{% set str = dbt.type_string() %}
-- mart_social_rising_words — the rising-WORDS list for the trend board, one row per
-- (week, rank): words whose share of posts jumped against the weeks before, counted from
-- the words in the posts so a trend shows up even when the AI tags it many ways and it
-- never forms a board row. See int_social_rising_words for how a word qualifies, and
-- analyses/social_rising_by_week.sql for the paste-and-run query behind the board tab.
--
-- is_on_board splits the list in two: FALSE = a potential new trend (most of its posts
-- count toward no board row); TRUE = rising inside a row that already ranks, which that
-- row's driven_by line says from the row's side.
--
-- on_board_as names a board row only when it holds a real part of the word's posts
-- (3+ and 20%+), or it is the row of a word that is on the board: one stray post on
-- Coconut Milk does not put egg cake "partly on the board".

with words as (

    select * from {{ ref('int_social_rising_words') }}

),

labels as (

    select week_start, concept_class, concept_norm, concept_label, board_rank
    from {{ ref('mart_social_trending_items') }}
    where is_top_n

),

weeks as (

    select distinct week_start, year_week
    from {{ ref('int_social_trend_board') }}

)

select
    w.week_start,
    wk.year_week,
    w.rising_rank,
    w.is_on_board,
    w.rising_word,
    w.words,
    w.word_count,
    w.also_written,
    w.posts,
    w.accounts,
    round(w.growth, 1)                                                  as growth,
    w.is_new,
    w.weekly_posts,
    round(w.on_board_share, 2)                                          as on_board_share,
    nullif(concat_ws('; ',
        case when w.is_on_board
                  or (w.row_1_posts >= 3 and w.row_1_posts >= 0.2 * w.posts)
             then l1.concept_label || ' (' || w.row_1_class || ' #' || cast(l1.board_rank as {{ str }})
                  || ', ' || cast(w.row_1_posts as {{ str }}) || ' of these posts)' end,
        case when w.row_2_posts >= 3 and w.row_2_posts >= 0.2 * w.posts
             then l2.concept_label || ' (' || w.row_2_class || ' #' || cast(l2.board_rank as {{ str }})
                  || ', ' || cast(w.row_2_posts as {{ str }}) || ' of these posts)' end
    ), '')                                                              as on_board_as,
    w.example_link_1,
    w.example_link_2,
    w.example_link_3,
    w.market,
    w.head_word
from words as w
inner join weeks as wk
    on wk.week_start = w.week_start
left join labels as l1
    on l1.week_start = w.week_start and l1.concept_class = w.row_1_class and l1.concept_norm = w.row_1_norm
left join labels as l2
    on l2.week_start = w.week_start and l2.concept_class = w.row_2_class and l2.concept_norm = w.row_2_norm
