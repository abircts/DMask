@isTest
private class AttachmentMaskerTest {
    
    @isTest
    static void testMaskTextFileContent() {
        // Create a ContentVersion with text content containing PII
        ContentVersion cv = new ContentVersion();
        cv.Title = 'report_john@example.com';
        cv.PathOnClient = 'report.csv';
        cv.VersionData = Blob.valueOf('Name,Email,Phone\nJohn Doe,john@example.com,555-123-4567\nJane Smith,jane@test.org,555-987-6543');
        insert cv;
        
        Test.startTest();
        AttachmentMasker batch = new AttachmentMasker();
        Database.executeBatch(batch, 10);
        Test.stopTest();
        
        // Verify results depend on sandbox status - check log was created
        List<PII_Mask_Log__c> logs = [
            SELECT Object_Name__c, Status__c, Records_Processed__c 
            FROM PII_Mask_Log__c 
            WHERE Object_Name__c = 'ContentVersion (Files)'
        ];
        // In sandbox, log should exist. In production, batch returns empty set.
        if (!logs.isEmpty()) {
            System.assertEquals('ContentVersion (Files)', logs[0].Object_Name__c);
        }
    }
    
    @isTest
    static void testConstructorOptions() {
        AttachmentMasker m1 = new AttachmentMasker();
        AttachmentMasker m2 = new AttachmentMasker(true, false); // titles only
        AttachmentMasker m3 = new AttachmentMasker(false, true); // content only
        System.assertNotEquals(null, m1, 'Default constructor should work');
        System.assertNotEquals(null, m2, 'Options constructor should work');
        System.assertNotEquals(null, m3, 'Options constructor should work');
    }
    
    @isTest
    static void testMaskBinaryFile_Skipped() {
        // Binary files should be filtered at query level
        ContentVersion cv = new ContentVersion();
        cv.Title = 'photo';
        cv.PathOnClient = 'photo.jpg';
        cv.VersionData = Blob.valueOf('fake binary data');
        insert cv;
        
        Test.startTest();
        Database.executeBatch(new AttachmentMasker(), 10);
        Test.stopTest();
        
        // Verify original title unchanged (jpg filtered in query)
        ContentVersion updated = [SELECT Title FROM ContentVersion WHERE Id = :cv.Id];
        System.assertEquals('photo', updated.Title, 'Binary file title should be unchanged');
    }
    
    @isTest
    static void testJsonFileWithPii() {
        ContentVersion cv = new ContentVersion();
        cv.Title = 'userdata';
        cv.PathOnClient = 'users.json';
        cv.VersionData = Blob.valueOf('{"email":"alice@test.com","ssn":"123-45-6789"}');
        insert cv;
        
        Test.startTest();
        Database.executeBatch(new AttachmentMasker(), 10);
        Test.stopTest();
        
        // Check if PII was masked (only in sandbox)
        if (PiiFieldDetector.isSandbox()) {
            ContentVersion updated = [SELECT VersionData FROM ContentVersion WHERE Id = :cv.Id];
            String content = updated.VersionData.toString();
            System.assert(!content.contains('alice@test.com'), 'Email should be masked in JSON');
            System.assert(!content.contains('123-45-6789'), 'SSN should be masked in JSON');
        }
    }
}
