@isTest
private class PiiFieldDetectorTest {
    
    @isTest
    static void testGetGlobalDescribe() {
        // Should return cached + non-null
        Map<String, Schema.SObjectType> desc1 = PiiFieldDetector.getGlobalDescribe();
        System.assertNotEquals(null, desc1, 'getGlobalDescribe should return non-null');
        System.assert(desc1.containsKey('contact'), 'Should contain Contact');
        
        // Second call should return same reference (cached)
        Map<String, Schema.SObjectType> desc2 = PiiFieldDetector.getGlobalDescribe();
        System.assertEquals(desc1, desc2, 'Should return cached reference');
    }
    
    @isTest
    static void testIsSandbox() {
        // Just verify it returns without error (can't control org type)
        Boolean result = PiiFieldDetector.isSandbox();
        System.assertNotEquals(null, result, 'isSandbox should return a value');
    }
    
    @isTest
    static void testValidateObjectName_Valid() {
        String result = PiiFieldDetector.validateObjectName('Contact');
        System.assertEquals('Contact', result, 'Should return canonical name');
    }
    
    @isTest
    static void testValidateObjectName_Invalid() {
        try {
            PiiFieldDetector.validateObjectName('FakeObject__xyz');
            System.assert(false, 'Should have thrown AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('Invalid object'), 'Should mention invalid object');
        }
    }
    
    @isTest
    static void testValidateObjectName_Blank() {
        try {
            PiiFieldDetector.validateObjectName('');
            System.assert(false, 'Should have thrown AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('blank'), 'Should mention blank');
        }
    }
    
    @isTest
    static void testValidateFieldNames() {
        Set<String> fields = new Set<String>{'Email', 'LastName', 'FAKE_FIELD_xyz'};
        Set<String> valid = PiiFieldDetector.validateFieldNames('Contact', fields);
        
        System.assert(valid.contains('Email'), 'Email should be valid');
        System.assert(valid.contains('LastName'), 'LastName should be valid');
        System.assert(!valid.contains('FAKE_FIELD_xyz'), 'Fake field should be filtered');
    }
    
    @isTest
    static void testDetectPiiFields() {
        List<SandboxDataMasker.FieldMaskInfo> fields = PiiFieldDetector.detectPiiFields('Contact');
        System.assert(!fields.isEmpty(), 'Contact should have PII fields');
        
        // Check that Email is detected
        Boolean hasEmail = false;
        for (SandboxDataMasker.FieldMaskInfo f : fields) {
            if (f.fieldName == 'Email') {
                hasEmail = true;
                System.assertEquals('email', f.piiCategory, 'Email should have category "email"');
            }
        }
        System.assert(hasEmail, 'Contact.Email should be detected');
    }
    
    @isTest
    static void testDetectPiiFields_InvalidObject() {
        List<SandboxDataMasker.FieldMaskInfo> fields = PiiFieldDetector.detectPiiFields('FakeObject999');
        System.assert(fields.isEmpty(), 'Invalid object should return empty');
    }
    
    @isTest
    static void testMaskPiiInText() {
        String text = 'Contact me at john@example.com or call 123-456-7890. SSN: 123-45-6789';
        String result = PiiFieldDetector.maskPiiInText(text);
        System.assert(!result.contains('john@example.com'), 'Email should be masked');
        System.assert(!result.contains('123-45-6789'), 'SSN should be masked');
        System.assert(result.contains('***'), 'Should contain masking tokens');
    }
    
    @isTest
    static void testMaskPiiInText_BlankText() {
        System.assertEquals(null, PiiFieldDetector.maskPiiInText(null), 'Null should return null');
        System.assertEquals('', PiiFieldDetector.maskPiiInText(''), 'Empty should return empty');
    }
    
    @isTest
    static void testIsTextFile() {
        System.assert(PiiFieldDetector.isTextFile('csv'), 'CSV should be text');
        System.assert(PiiFieldDetector.isTextFile('TXT'), 'TXT uppercase should be text');
        System.assert(PiiFieldDetector.isTextFile('json'), 'JSON should be text');
        System.assert(!PiiFieldDetector.isTextFile('pdf'), 'PDF should not be text');
        System.assert(!PiiFieldDetector.isTextFile('xlsx'), 'XLSX should not be text');
        System.assert(!PiiFieldDetector.isTextFile(null), 'Null should not be text');
        System.assert(!PiiFieldDetector.isTextFile(''), 'Empty should not be text');
    }
    
    @isTest
    static void testBuildSafeQuery() {
        List<SandboxDataMasker.FieldMaskInfo> fields = new List<SandboxDataMasker.FieldMaskInfo>{
            new SandboxDataMasker.FieldMaskInfo('Email', Schema.DisplayType.EMAIL, 'email'),
            new SandboxDataMasker.FieldMaskInfo('LastName', Schema.DisplayType.STRING, 'name')
        };
        
        String query = PiiFieldDetector.buildSafeQuery('Contact', fields);
        System.assert(query.contains('FROM Contact'), 'Query should target Contact');
        System.assert(query.contains('Email'), 'Query should include Email');
        System.assert(query.contains('Id'), 'Query should include Id');
    }
    
    @isTest
    static void testBuildSafeQuery_InvalidObject() {
        try {
            PiiFieldDetector.buildSafeQuery('FakeObj__z', new List<SandboxDataMasker.FieldMaskInfo>());
            System.assert(false, 'Should throw for invalid object');
        } catch (AuraHandledException e) {
            System.assert(true, 'Expected exception thrown');
        }
    }
}
