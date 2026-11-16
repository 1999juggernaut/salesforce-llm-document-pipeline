// Run once per org (Developer Console > Execute Anonymous, or `sf apex run --file scripts/set_callback_token.apex`).
// Use a long random value. Salesforce sends it with each job; the Python service echoes it on the callback and never logs it.
FileExtractionConfig__c cfg = FileExtractionConfig__c.getOrgDefaults();
cfg.SetupOwnerId = UserInfo.getOrganizationId();
cfg.CallbackToken__c = 'REPLACE_WITH_A_LONG_RANDOM_SECRET';
upsert cfg;
System.debug('Callback token configured.');
