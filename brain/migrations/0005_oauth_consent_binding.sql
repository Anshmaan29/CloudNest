-- Bind token/browser origins to the one actual callback the owner approved.
-- Existing approved requests already retain this value through grant expiry.
CREATE UNIQUE INDEX oauth_consent_grant ON oauth_requests(grant_id) WHERE grant_id IS NOT NULL;
