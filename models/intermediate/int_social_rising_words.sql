{{ config(tags=['social']) }}
{% set base_weeks = var('social_words_baseline_weeks') %}
{% set cap = var('social_words_account_cap') %}
{% set str = dbt.type_string() %}
-- int_social_rising_words — WORDS RISING THIS WEEK, whether or not they have a board row
-- yet. One row per (week, story), best first. A potential trend shows up here BEFORE it
-- can rank, because it is counted from the words in the posts, not from the AI's tags:
-- in 2026-W42 ต้มโคล้ง (tom klong) was the strongest riser of all (17 posts, 8 accounts,
-- ~9x its usual share) while its posts were spread over ~30 tagged products, none on
-- the board. Not the product Rising list (int_social_trend_board.rising_rank): that one
-- ranks board products; this one ranks words.
--
-- RISING = the word's share of the week's posts against its share over the
-- social_words_baseline_weeks before (pooled), smoothed so a word from nothing does not
-- divide by zero:  growth = (per_k + 0.5) / (base_per_k + 0.5), per 1,000 posts.
-- Shares, not counts: the feed is 5,038 posts one week and 196 another.
--
-- NOISE IT REFUSES, found by reading the posts behind the first list:
--   * a YouTube comment thread counts once (int_social_word_posts);
--   * one account counts at most social_words_account_cap posts a week — one account
--     replying 11 times was most of "fish ball", Lazada listings most of "cashew";
--   * and may post at most social_rising_words_max_posts_per_account raw posts per
--     account on average (a shop listing its SKUs);
--   * social_rising_words_min_posts posts from social_rising_words_min_accounts accounts;
--   * not an everyday word: a usual share above social_rising_words_max_base_per_k per
--     1,000 posts moves with the feed's mix (category words are stoplisted upstream).
-- Words that ride on the same posts are ONE story (macros/social_word_stories): the
-- Starbucks holiday menu is one row, not five.
--
-- ON THE BOARD when half its posts already count on a board row, or when its name IS a
-- board row's spelling (Belly Jelly has a row although only 3 of its 9 posts were tagged
-- to it). The rest are the potential new trends. The two board rows holding most of
-- its posts are kept for "where it sits".

with weeks as (

    select distinct week_start
    from {{ ref('int_social_trend_board') }}

),

board as (

    select week_start, concept_class, concept_norm, board_rank
    from {{ ref('int_social_trend_board') }}
    where is_on_board

),

week_threads as (

    select week_start, count(distinct thread_key) as week_threads
    from {{ ref('int_social_word_posts') }}
    group by 1

),

baseline_size as (

    select wk.week_start, sum(wt.week_threads) as base_threads
    from weeks as wk
    inner join week_threads as wt
        on wt.week_start between cast({{ dbt.dateadd('day', -7 * base_weeks, 'wk.week_start') }} as date)
                             and cast({{ dbt.dateadd('day', -7, 'wk.week_start') }} as date)
    group by 1

),

-- each word's posts per week; an account counts at most `cap` times
word_owner_week as (

    select term, week_start, owner, count(distinct thread_key) as threads
    from {{ ref('int_social_post_words') }}
    group by 1, 2, 3

),

word_week as (

    select
        term,
        week_start,
        sum(least(threads, {{ cap }}))                                  as posts,
        sum(threads)                                                    as raw_posts,
        count(*)                                                        as accounts
    from word_owner_week
    group by 1, 2

),

word_baseline as (

    select wk.week_start, ww.term, sum(ww.posts) as base_posts
    from weeks as wk
    inner join word_week as ww
        on ww.week_start between cast({{ dbt.dateadd('day', -7 * base_weeks, 'wk.week_start') }} as date)
                             and cast({{ dbt.dateadd('day', -7, 'wk.week_start') }} as date)
    group by 1, 2

),

scored as (

    select
        ww.week_start,
        ww.term,
        ww.posts,
        ww.raw_posts,
        ww.accounts,
        1000.0 * ww.posts / wt.week_threads                             as per_k,
        1000.0 * coalesce(wb.base_posts, 0) / bs.base_threads           as base_per_k
    from weeks as wk
    inner join word_week as ww
        on ww.week_start = wk.week_start
    inner join week_threads as wt
        on wt.week_start = wk.week_start
    inner join baseline_size as bs
        on bs.week_start = wk.week_start
    left join word_baseline as wb
        on wb.week_start = wk.week_start and wb.term = ww.term
    where bs.base_threads > 0

),

cands as (

    select
        week_start,
        term,
        posts                                                           as n_posts,
        accounts,
        per_k,
        base_per_k,
        (per_k + 0.5) / (base_per_k + 0.5)                              as growth
    from scored
    where posts >= {{ var('social_rising_words_min_posts') }}
      and accounts >= {{ var('social_rising_words_min_accounts') }}
      and raw_posts <= {{ var('social_rising_words_max_posts_per_account') }} * accounts
      and base_per_k <= {{ var('social_rising_words_max_base_per_k') }}
      and (per_k + 0.5) / (base_per_k + 0.5) >= {{ var('social_rising_words_min_growth') }}

),

cand_hits as (

    select distinct pw.week_start, pw.term, pw.thread_key as post_key
    from {{ ref('int_social_post_words') }} as pw
    inner join cands as c
        on c.week_start = pw.week_start and c.term = pw.term

),

{{ social_word_stories('cands', 'cand_hits', ['week_start'], 'rw', var('social_rising_words_story_overlap')) }},

-- every post of the story's words, this week and the baseline weeks before it
story_hits as (

    select distinct
        s.week_start                                                    as target_week,
        s.story,
        pw.week_start,
        pw.thread_key,
        pw.owner,
        pw.mention_id
    from rw_story as s
    inner join rw_grp as g
        on g.week_start = s.week_start and g.grp = s.grp
    inner join {{ ref('int_social_post_words') }} as pw
        on  pw.term = g.term
        and pw.week_start between cast({{ dbt.dateadd('day', -7 * base_weeks, 's.week_start') }} as date)
                              and s.week_start

),

story_week as (

    select
        target_week,
        story,
        week_start,
        sum(least(threads, {{ cap }}))                                  as posts,
        sum(threads)                                                    as raw_posts,
        count(*)                                                        as accounts
    from (
        select target_week, story, week_start, owner, count(distinct thread_key) as threads
        from story_hits
        group by 1, 2, 3, 4
    ) as o
    group by 1, 2, 3

),

story_stats as (

    select
        sw.target_week                                                  as week_start,
        sw.story,
        max(case when sw.week_start = sw.target_week then sw.posts end)      as posts,
        max(case when sw.week_start = sw.target_week then sw.raw_posts end)  as raw_posts,
        max(case when sw.week_start = sw.target_week then sw.accounts end)   as accounts,
        sum(case when sw.week_start < sw.target_week then sw.posts else 0 end) as base_posts,
        -- posts per week, oldest first, ending with this week
        concat_ws(' · '
        {%- for k in range(base_weeks, -1, -1) %},
            cast(coalesce(max(case when sw.week_start =
                cast({{ dbt.dateadd('day', -7 * k, 'sw.target_week') }} as date) then sw.posts end), 0)
                as {{ str }})
        {%- endfor %})                                                  as weekly_posts
    from story_week as sw
    group by 1, 2

),

story_on_board as (

    select sh.target_week as week_start, sh.story, count(distinct sh.thread_key) as on_board_posts
    from story_hits as sh
    inner join (
        select distinct pp.mention_id
        from {{ ref('int_social_post_products') }} as pp
        inner join board as b
            on  b.week_start    = pp.week_start
            and b.concept_class = pp.concept_class
            and b.concept_norm  = pp.concept_norm
    ) as ob
        on ob.mention_id = sh.mention_id
    where sh.week_start = sh.target_week
    group by 1, 2

),

-- the board rows that count the story's posts this week, most first
story_rows as (

    select
        week_start,
        story,
        concept_class,
        concept_norm,
        row_posts,
        row_number() over (partition by week_start, story order by row_posts desc, board_rank) as row_rank
    from (
        select
            sh.target_week                                              as week_start,
            sh.story,
            b.concept_class,
            b.concept_norm,
            b.board_rank,
            count(distinct sh.mention_id)                               as row_posts
        from story_hits as sh
        inner join {{ ref('int_social_post_products') }} as pp
            on pp.mention_id = sh.mention_id
        inner join board as b
            on  b.week_start    = sh.target_week
            and b.concept_class = pp.concept_class
            and b.concept_norm  = pp.concept_norm
        where sh.week_start = sh.target_week
        group by 1, 2, 3, 4, 5
    ) as r

),

-- the story's words in reading order: biggest first
story_word as (

    select
        s.week_start,
        s.story,
        s.head,
        s.also_written,
        case when w.is_latin then s.head
             when w.gloss is not null then w.gloss || ' (' || s.head || ')'
             else s.head end                                            as word_label,
        count(*) over (partition by s.week_start, s.story)              as n_words,
        row_number() over (
            partition by s.week_start, s.story order by s.grp_posts desc, length(s.head) desc, s.head
        )                                                               as word_rank
    from rw_story as s
    inner join {{ ref('int_social_words') }} as w
        on w.term = s.head

),

story_label as (

    select
        week_start,
        story,
        max(case when word_rank = 1 then head end)                      as head_word,
        max(case when word_rank = 1 then word_label end)                as rising_word,
        concat_ws(' + ',
            max(case when word_rank = 1 then word_label end),
            max(case when word_rank = 2 then word_label end),
            max(case when word_rank = 3 then word_label end))
        || case when max(n_words) > 3
                then ' +' || cast(max(n_words) - 3 as {{ str }}) || ' more' else '' end
                                                                        as words,
        max(n_words)                                                    as word_count,
        nullif(concat_ws(', ',
            max(case when word_rank = 1 then also_written end),
            max(case when word_rank = 2 then also_written end)), '')    as also_written
    from story_word
    group by 1, 2

),

-- its name IS a board row's spelling this week (any board, either class)
named_row as (

    select distinct sl.week_start, sl.story
    from story_label as sl
    inner join (select distinct concept_norm, term from {{ ref('int_social_post_products') }}) as sp
        on sp.term = sl.head_word
    inner join board as b
        on b.week_start = sl.week_start and b.concept_norm = sp.concept_norm

),

story_examples as (

    select
        week_start,
        story,
        max(case when ex_rank = 1 then link end)                        as example_link_1,
        max(case when ex_rank = 2 then link end)                        as example_link_2,
        max(case when ex_rank = 3 then link end)                        as example_link_3
    from (
        select
            sh.target_week                                              as week_start,
            sh.story,
            sh.thread_key,
            max(wp.link)                                                as link,
            row_number() over (
                partition by sh.target_week, sh.story order by max(wp.views) desc, max(wp.link)
            )                                                           as ex_rank
        from story_hits as sh
        inner join {{ ref('int_social_word_posts') }} as wp
            on wp.mention_id = sh.mention_id
        where sh.week_start = sh.target_week
        group by 1, 2, 3
    ) as e
    group by 1, 2

),

story_market as (

    select week_start, story, market
    from (
        select
            sh.target_week                                              as week_start,
            sh.story,
            wp.market,
            row_number() over (
                partition by sh.target_week, sh.story
                order by count(distinct sh.thread_key) desc, wp.market
            )                                                           as _rn
        from story_hits as sh
        inner join {{ ref('int_social_word_posts') }} as wp
            on wp.mention_id = sh.mention_id
        where sh.week_start = sh.target_week
        group by 1, 2, 3
    ) as m
    where _rn = 1

),

final as (

    select
        st.week_start,
        st.story,
        sl.head_word,
        sl.rising_word,
        sl.words,
        sl.word_count,
        sl.also_written,
        st.posts,
        st.accounts,
        (1000.0 * st.posts / wt.week_threads + 0.5)
            / (1000.0 * st.base_posts / bs.base_threads + 0.5)          as growth,
        st.base_posts = 0                                               as is_new,
        st.weekly_posts,
        coalesce(ob.on_board_posts, 0) * 1.0 / st.raw_posts             as on_board_share,
        (coalesce(ob.on_board_posts, 0) >= 0.5 * st.raw_posts or nr.story is not null) as is_on_board,
        r1.concept_class                                                as row_1_class,
        r1.concept_norm                                                 as row_1_norm,
        r1.row_posts                                                    as row_1_posts,
        r2.concept_class                                                as row_2_class,
        r2.concept_norm                                                 as row_2_norm,
        r2.row_posts                                                    as row_2_posts,
        ex.example_link_1,
        ex.example_link_2,
        ex.example_link_3,
        mk.market
    from story_stats as st
    inner join story_label as sl
        on sl.week_start = st.week_start and sl.story = st.story
    inner join week_threads as wt
        on wt.week_start = st.week_start
    inner join baseline_size as bs
        on bs.week_start = st.week_start
    left join story_on_board as ob
        on ob.week_start = st.week_start and ob.story = st.story
    left join named_row as nr
        on nr.week_start = st.week_start and nr.story = st.story
    left join story_rows as r1
        on r1.week_start = st.week_start and r1.story = st.story and r1.row_rank = 1
    left join story_rows as r2
        on r2.week_start = st.week_start and r2.story = st.story and r2.row_rank = 2
    left join story_examples as ex
        on ex.week_start = st.week_start and ex.story = st.story
    left join story_market as mk
        on mk.week_start = st.week_start and mk.story = st.story

)

select
    *,
    row_number() over (partition by week_start order by growth desc, posts desc, story) as rising_rank
from final
qualify row_number() over (partition by week_start order by growth desc, posts desc, story)
        <= {{ var('social_rising_words_count') }}
