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
}
