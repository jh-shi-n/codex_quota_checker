-- 목적: 계정별 일별 토큰 집계의 장기 보관
-- 저장 범위: 계정 경로 식별자·날짜·토큰 숫자·세션 수·집계 시각
PRAGMA foreign_keys = ON;
CREATE TABLE IF NOT EXISTS token_history_accounts (
    account_id TEXT PRIMARY KEY,
    home_identity TEXT NOT NULL,
    account_identity TEXT,
    updated_at REAL NOT NULL
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS token_daily_history (
    account_id TEXT NOT NULL REFERENCES token_history_accounts(account_id) ON DELETE CASCADE,
    day TEXT NOT NULL,
    input_tokens INTEGER NOT NULL,
    output_tokens INTEGER NOT NULL,
    cached_input_tokens INTEGER,
    session_count INTEGER NOT NULL,
    updated_at REAL NOT NULL,
    PRIMARY KEY (account_id, day)
) WITHOUT ROWID;
