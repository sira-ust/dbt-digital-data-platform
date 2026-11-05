-- Words RISING each week on social — paste into the Databricks SQL editor and run, then
-- use the download button for Excel/CSV. The "Rising this week" tab of the trend board;
-- social_trending_by_week.sql is the board itself.
--
-- Plain SQL with no Jinja, like every file in analyses/: tables are named in full and the
-- dialect is Databricks.
--
-- One row per (week, word), newest week first, potential new trends before words already
-- on the board, biggest jump first. To narrow it:
--   latest week only    -> where r.week_start = (select max(week_start) from ust_databricks.ust_reporting.mart_social_rising_words)
--   new trends only     -> and not r.is_on_board
--
-- WHAT THIS IS. Food words whose share of posts jumped compared with the 4 weeks before.
-- They are counted from the words in the posts themselves, so a trend shows up even
-- when the AI labels it many different ways and it never forms a board row of its own:
-- in 2026-W42 ต้มโคล้ง (tom klong) was the biggest riser of all while its posts were
-- spread over ~30 tagged products, none on the board.
--
--   on_board        no  = a POTENTIAL NEW TREND: most of its posts count toward no row.
--                   yes = rising inside a row that already ranks; that row's driven_by
--                         line on the board says the same thing from the row's side.
--   growth          times its usual share of posts (2.0 = twice as common as usual).
--                   Shares, not counts, so a bigger feed does not make everything rise.
--   posts           a YouTube video's comment thread counts once, and one account at most
--                   twice, so one account replying eleven times is one voice.
--   weekly_posts    the 4 weeks before and this one, oldest first.
--   words           words that ride on the same posts are ONE row: the Starbucks holiday
--                   menu is "marshmallow + white chocolate + mocha +2 more", not five rows.
--
-- BUZZ, NOT DEMAND. A promotion or a celebrity post rises too. Open the example posts
-- before acting; for what our own customers search, see social_trending_by_week.sql.

select
    r.year_week                                              as week,
    r.week_start,
    r.rising_rank                                            as rank,
    case when r.is_on_board then 'yes' else 'no' end         as on_board,
    r.rising_word,
    r.words,
    r.also_written,
    r.posts,
    r.accounts,
    r.growth,
    case when r.is_new then 'yes' else 'no' end              as is_new,
    r.weekly_posts,
    r.on_board_as,
    r.market,
    r.example_link_1,
    r.example_link_2,
    r.example_link_3
from ust_databricks.ust_reporting.mart_social_rising_words as r
order by r.week_start desc,
         case when r.is_on_board then 1 else 0 end,
         r.growth desc,
         r.rising_rank
