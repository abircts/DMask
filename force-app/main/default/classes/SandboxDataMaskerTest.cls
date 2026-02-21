@isTest
private class SandboxDataMaskerTest {

    @isTest
    static void testMaskingLogic() {
        // Setup Test Data
        Contact c = new Contact(LastName = 'TestUser', Email = 'test@example.com', MobilePhone = '1234567890');
        insert c;
        
        Lead l = new Lead(LastName = 'TestLead', Company = 'TestCo', Email = 'lead@example.com');
        insert l;

        // Mock Configs
        List<PII_Mask_Config__mdt> mocks = new List<PII_Mask_Config__mdt>();
        
        // Contact Email -> Suffix
        PII_Mask_Config__mdt c1 = new PII_Mask_Config__mdt();
        c1.Object_API_Name__c = 'Contact';
        c1.Field_API_Name__c = 'Email';
        c1.Masking_Type__c = 'Suffix';
        c1.Pattern__c = '.testinvalid';
        mocks.add(c1);

        // Contact Mobile -> Static
        PII_Mask_Config__mdt c2 = new PII_Mask_Config__mdt();
        c2.Object_API_Name__c = 'Contact';
        c2.Field_API_Name__c = 'MobilePhone';
        c2.Masking_Type__c = 'Static';
        c2.Pattern__c = '000-000-0000';
        mocks.add(c2);
        
        // Lead Email -> Random
        PII_Mask_Config__mdt l1 = new PII_Mask_Config__mdt();
        l1.Object_API_Name__c = 'Lead';
        l1.Field_API_Name__c = 'Email';
        l1.Masking_Type__c = 'Random';
        mocks.add(l1);

        SandboxDataMasker.mockConfigs = mocks;

        Test.startTest();
        SandboxDataMasker.runAll();
        Test.stopTest();

        // Verify Contact
        Contact cUpdated = [SELECT Email, MobilePhone FROM Contact WHERE Id = :c.Id];
        System.assert(cUpdated.Email.endsWith('.testinvalid'), 'Email should have suffix');
        System.assertEquals('000-000-0000', cUpdated.MobilePhone, 'Mobile should be static masked');

        // Verify Lead
        Lead lUpdated = [SELECT Email FROM Lead WHERE Id = :l.Id];
        System.assertNotEquals('lead@example.com', lUpdated.Email, 'Lead email should be masked');
        System.assert(lUpdated.Email.startsWith('Masked_'), 'Lead email should start with Masked_');
    }
    
    @isTest
    static void testAllMaskingStrategies() {
        Contact c = new Contact(
            LastName = 'StrategyTest',
            Email = 'strat@example.com',
            Phone = '555-111-2222',
            FirstName = 'TestFirst',
            MailingStreet = '123 Test Ave'
        );
        insert c;
        
        // Test auto-detect (no mock configs = use detectPiiFields path)
        SandboxDataMasker masker = new SandboxDataMasker(new List<String>{ 'Contact' });
        List<SandboxDataMasker.FieldMaskInfo> fields = SandboxDataMasker.detectPiiFields('Contact');
        System.assert(!fields.isEmpty(), 'Should auto-detect PII fields on Contact');
        
        // Test simulateMask for email
        SandboxDataMasker.FieldMaskInfo emailInfo = null;
        for (SandboxDataMasker.FieldMaskInfo f : fields) {
            if (f.fieldName == 'Email') { emailInfo = f; break; }
        }
        if (emailInfo != null) {
            sObject clone = c.clone(true, true, true, true);
            masker.simulateMask(clone, emailInfo);
            System.assertNotEquals('strat@example.com', clone.get('Email'), 'Email should be masked');
        }
    }
    
    @isTest
    static void testRegexMasking() {
        Contact c = new Contact(LastName = 'RegexTest', Email = 'regex@example.com');
        insert c;
        
        // Create FieldMaskInfo with regex override
        SandboxDataMasker.FieldMaskInfo info = new SandboxDataMasker.FieldMaskInfo('Email', Schema.DisplayType.EMAIL, 'email');
        info.maskOverride = 'Regex';
        info.regexPattern = '[a-zA-Z]+@';
        
        SandboxDataMasker masker = new SandboxDataMasker(new List<String>());
        sObject clone = c.clone(true, true, true, true);
        masker.simulateMask(clone, info);
        
        String masked = (String)clone.get('Email');
        System.assertNotEquals('regex@example.com', masked, 'Regex should mask email');
        System.assert(masked.contains('***'), 'Should contain masked token');
    }
    
    @isTest
    static void testRegexMasking_NoPattern() {
        Contact c = new Contact(LastName = 'RegexNone', Email = 'nopattern@example.com');
        insert c;
        
        // Regex override without a pattern => falls back to generic masking
        SandboxDataMasker.FieldMaskInfo info = new SandboxDataMasker.FieldMaskInfo('Email', Schema.DisplayType.EMAIL, 'email');
        info.maskOverride = 'Regex';
        info.regexPattern = null;
        
        SandboxDataMasker masker = new SandboxDataMasker(new List<String>());
        sObject clone = c.clone(true, true, true, true);
        masker.simulateMask(clone, info);
        
        String masked = (String)clone.get('Email');
        System.assert(masked.startsWith('MASKED_'), 'Should fallback to MASKED_ prefix');
    }
    
    @isTest
    static void testRetryConstructor() {
        Contact c = new Contact(LastName = 'RetryTest', Email = 'retry@example.com');
        insert c;
        
        Set<Id> retryIds = new Set<Id>{ c.Id };
        SandboxDataMasker masker = new SandboxDataMasker('Contact', retryIds);
        System.assertNotEquals(null, masker, 'Retry constructor should work');
    }
    
    @isTest
    static void testFieldMaskInfo() {
        SandboxDataMasker.FieldMaskInfo info = new SandboxDataMasker.FieldMaskInfo('TestField__c', Schema.DisplayType.STRING, 'name');
        System.assertEquals('TestField__c', info.fieldName);
        System.assertEquals(Schema.DisplayType.STRING, info.fieldType);
        System.assertEquals('name', info.piiCategory);
        System.assertEquals(null, info.maskOverride);
        System.assertEquals(null, info.regexPattern);
    }
    
    @isTest
    static void testSimulateMask_NullValue() {
        Contact c = new Contact(LastName = 'NullTest'); // Email is null
        insert c;
        
        SandboxDataMasker.FieldMaskInfo info = new SandboxDataMasker.FieldMaskInfo('Email', Schema.DisplayType.EMAIL, 'email');
        SandboxDataMasker masker = new SandboxDataMasker(new List<String>());
        
        sObject clone = c.clone(true, true, true, true);
        masker.simulateMask(clone, info);
        
        System.assertEquals(null, clone.get('Email'), 'Null email should remain null');
    }
}
