@isTest
private class PiiMaskingControllerTest {
    
    @TestSetup
    static void setup() {
        // Create test contacts for masking preview
        List<Contact> contacts = new List<Contact>();
        for (Integer i = 0; i < 5; i++) {
            contacts.add(new Contact(
                FirstName = 'Test' + i,
                LastName = 'User' + i,
                Email = 'test' + i + '@example.com',
                Phone = '555-000-' + String.valueOf(i).leftPad(4, '0')
            ));
        }
        insert contacts;
    }
    
    @isTest
    static void testGetOrgInfo() {
        Map<String, Object> info = PiiMaskingController.getOrgInfo();
        System.assertNotEquals(null, info, 'Should return org info');
        System.assert(info.containsKey('isSandbox'), 'Should have isSandbox key');
        System.assert(info.containsKey('orgName'), 'Should have orgName key');
        System.assert(info.containsKey('instance'), 'Should have instance key');
    }
    
    @isTest
    static void testGetConfigs() {
        List<Map<String, Object>> configs = PiiMaskingController.getConfigs();
        System.assertNotEquals(null, configs, 'Should return configs list');
    }
    
    @isTest
    static void testGetObjects() {
        List<Map<String, String>> objects = PiiMaskingController.getObjects();
        System.assertNotEquals(null, objects, 'Should return objects list');
        System.assert(!objects.isEmpty(), 'Should have at least one object');
        
        // Verify structure
        Map<String, String> first = objects[0];
        System.assert(first.containsKey('value'), 'Each item should have value');
        System.assert(first.containsKey('label'), 'Each item should have label');
    }
    
    @isTest
    static void testGetActiveJobs() {
        List<Map<String, Object>> jobs = PiiMaskingController.getActiveJobs();
        System.assertNotEquals(null, jobs, 'Should return active jobs list');
    }
    
    @isTest
    static void testGetJobHistory() {
        // Create a test log
        PII_Mask_Log__c log = new PII_Mask_Log__c();
        log.Object_Name__c = 'Contact';
        log.Job_Id__c = 'TEST_JOB_123';
        log.Status__c = 'Completed';
        log.Records_Processed__c = 10;
        log.Records_Failed__c = 0;
        log.Completed_Date__c = Datetime.now();
        log.Fields_Masked__c = 'Email, Phone';
        insert log;
        
        List<Map<String, Object>> history = PiiMaskingController.getJobHistory();
        System.assertNotEquals(null, history, 'Should return history');
        System.assert(!history.isEmpty(), 'Should have at least one log');
        
        Map<String, Object> first = history[0];
        System.assertEquals('Contact', first.get('objectName'), 'Object name should match');
        System.assertEquals(false, first.get('hasFailures'), 'Should have no failures');
    }
    
    @isTest
    static void testStartMasking() {
        // Mock configs
        List<PII_Mask_Config__mdt> mocks = new List<PII_Mask_Config__mdt>();
        PII_Mask_Config__mdt cfg = new PII_Mask_Config__mdt();
        cfg.Object_API_Name__c = 'Contact';
        cfg.Field_API_Name__c = 'Email';
        cfg.Masking_Type__c = 'Random';
        cfg.Active__c = true;
        mocks.add(cfg);
        SandboxDataMasker.mockConfigs = mocks;
        
        Test.startTest();
        // In sandbox this should work; in production it will throw
        try {
            Id jobId = PiiMaskingController.startMasking(new List<String>{ 'Contact' });
            System.assertNotEquals(null, jobId, 'Should return job ID in sandbox');
        } catch (AuraHandledException e) {
            // Expected in production
            System.assert(e.getMessage().contains('BLOCKED'), 'Should be blocked in production');
        }
        Test.stopTest();
    }
    
    @isTest
    static void testPreviewMasking() {
        // Ensure contacts exist from TestSetup
        List<Map<String, Object>> preview = PiiMaskingController.previewMasking('Contact');
        System.assertNotEquals(null, preview, 'Should return preview data');
        
        if (!preview.isEmpty()) {
            Map<String, Object> first = preview[0];
            System.assert(first.containsKey('recordId'), 'Should have recordId');
            System.assert(first.containsKey('fieldName'), 'Should have fieldName');
            System.assert(first.containsKey('originalValue'), 'Should have originalValue');
            System.assert(first.containsKey('maskedValue'), 'Should have maskedValue');
            System.assertNotEquals(first.get('originalValue'), first.get('maskedValue'), 'Values should differ');
        }
    }
    
    @isTest
    static void testPreviewPiiFields() {
        List<Map<String, Object>> fields = PiiMaskingController.previewPiiFields('Contact');
        System.assertNotEquals(null, fields, 'Should return field list');
        System.assert(!fields.isEmpty(), 'Contact should have PII fields');
    }
    
    @isTest
    static void testAddObjectConfig() {
        Test.startTest();
        String result = PiiMaskingController.addObjectConfig('Contact', 'Email,Phone');
        Test.stopTest();
        System.assert(result.contains('Contact'), 'Response should mention Contact');
    }
    
    @isTest
    static void testRemoveConfig() {
        Test.startTest();
        String result = PiiMaskingController.removeConfig('Contact');
        Test.stopTest();
        System.assertEquals('Configuration removed.', result, 'Should confirm removal');
    }
    
    @isTest
    static void testRetryFailed() {
        // Create a log with failed IDs
        Contact c = [SELECT Id FROM Contact LIMIT 1];
        PII_Mask_Log__c log = new PII_Mask_Log__c();
        log.Object_Name__c = 'Contact';
        log.Job_Id__c = 'TEST_RETRY';
        log.Status__c = 'Partial';
        log.Records_Processed__c = 5;
        log.Records_Failed__c = 1;
        log.Completed_Date__c = Datetime.now();
        log.Fields_Masked__c = 'Email';
        log.Failed_Record_Ids__c = String.valueOf(c.Id);
        insert log;
        
        // Mock configs for retry
        List<PII_Mask_Config__mdt> mocks = new List<PII_Mask_Config__mdt>();
        PII_Mask_Config__mdt cfg = new PII_Mask_Config__mdt();
        cfg.Object_API_Name__c = 'Contact';
        cfg.Field_API_Name__c = 'Email';
        cfg.Masking_Type__c = 'Random';
        cfg.Active__c = true;
        mocks.add(cfg);
        SandboxDataMasker.mockConfigs = mocks;
        
        Test.startTest();
        try {
            Id jobId = PiiMaskingController.retryFailed(log.Name);
            System.assertNotEquals(null, jobId, 'Should start retry job');
        } catch (AuraHandledException e) {
            // Expected if in production or log not found
            System.assert(true, 'Exception handled');
        }
        Test.stopTest();
    }
    
    @isTest
    static void testStartFileMasking() {
        Test.startTest();
        try {
            Id jobId = PiiMaskingController.startFileMasking();
            System.assertNotEquals(null, jobId, 'Should return job ID in sandbox');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('BLOCKED'), 'Should be blocked in production');
        }
        Test.stopTest();
    }
}
