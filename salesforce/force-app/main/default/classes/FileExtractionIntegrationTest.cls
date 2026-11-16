@IsTest
private class FileExtractionIntegrationTest {

    private static final String TEST_CALLBACK_TOKEN = 'unit-test-token';

    private class SuccessfulExtractionMock implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            Map<String, Object> body =
                (Map<String, Object>) JSON.deserializeUntyped(req.getBody());

            System.assertEquals(TEST_CALLBACK_TOKEN, (String) body.get('callback_token'));
            System.assert(!String.isBlank((String) body.get('callback_url')));
            System.assert(!String.isBlank(String.valueOf(body.get('salesforce_record_id'))));

            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setHeader('Content-Type', 'application/json');
            res.setBody(JSON.serialize(new Map<String, Object>{
                'success' => true,
                'file_name' => 'test.pdf',
                'user_query' => 'Extract invoice details',
                'extracted_text' => 'Invoice Number: INV-100',
                'character_count' => 24,
                'within_salesforce_limit' => true
            }));
            return res;
        }
    }

    @IsTest
    static void testTriggerEnqueuesQueueableForSupportedFile() {
        setCallbackToken(TEST_CALLBACK_TOKEN);
        Test.setMock(HttpCalloutMock.class, new SuccessfulExtractionMock());

        ContentVersion cv = new ContentVersion();
        cv.Title = 'Invoice_March';
        cv.PathOnClient = 'Invoice_March.pdf';
        cv.VersionData = Blob.valueOf('sample pdf bytes');

        Test.startTest();
        insert cv;
        Test.stopTest();

        Integer queuedJobs = [
            SELECT COUNT()
            FROM AsyncApexJob
            WHERE JobType = 'Queueable'
            AND ApexClass.Name = 'FileExtractionCallout'
        ];

        System.assertEquals(1, queuedJobs, 'Expected exactly one extraction queueable job.');
    }

    @IsTest
    static void testTriggerSkipsUnsupportedFile() {
        ContentVersion cv = new ContentVersion();
        cv.Title = 'Notes_File';
        cv.PathOnClient = 'Notes_File.txt';
        cv.VersionData = Blob.valueOf('plain text file');

        Test.startTest();
        insert cv;
        Test.stopTest();

        Integer queuedJobs = [
            SELECT COUNT()
            FROM AsyncApexJob
            WHERE JobType = 'Queueable'
            AND ApexClass.Name = 'FileExtractionCallout'
        ];

        System.assertEquals(0, queuedJobs, 'Unsupported file type should not enqueue extraction queueable.');
    }

    @IsTest
    static void testBuildExtractionQuerySupportsAllConfiguredTypes() {
        System.assertStartsWith(
            'PDF:',
            ContentVersionTriggerHandler.buildExtractionQuery('Quarterly_Report', 'PDF')
        );

        for (String wordType : new List<String>{'DOCX', 'WORD_X', 'WORD', 'DOC'}) {
            System.assertStartsWith(
                'DOCX:',
                ContentVersionTriggerHandler.buildExtractionQuery('Contract_File', wordType),
                'Expected DOCX prompt for type ' + wordType
            );
        }

        for (String spreadsheetType : new List<String>{'XLSX', 'EXCEL_X', 'EXCEL', 'XLS'}) {
            System.assertStartsWith(
                'XLSX:',
                ContentVersionTriggerHandler.buildExtractionQuery('Revenue_Data', spreadsheetType),
                'Expected XLSX prompt for type ' + spreadsheetType
            );
        }

        System.assertEquals(
            'File type not supported for automated extraction.',
            ContentVersionTriggerHandler.buildExtractionQuery('Random_File', 'TXT')
        );
    }

    @IsTest
    static void testCalloutNormalizesExtensionsForSupportedAliases() {
        System.assertEquals('pdf', FileExtractionCallout.getFileExtension('PDF'));

        for (String wordType : new List<String>{'DOCX', 'WORD_X', 'WORD', 'DOC'}) {
            System.assertEquals(
                'docx',
                FileExtractionCallout.getFileExtension(wordType),
                'Expected DOCX extension for type ' + wordType
            );
        }

        for (String spreadsheetType : new List<String>{'XLSX', 'EXCEL_X', 'EXCEL', 'XLS'}) {
            System.assertEquals(
                'xlsx',
                FileExtractionCallout.getFileExtension(spreadsheetType),
                'Expected XLSX extension for type ' + spreadsheetType
            );
        }
    }

    @IsTest
    static void testInvoiceCallbackRejectsMissingToken() {
        setCallbackToken(TEST_CALLBACK_TOKEN);

        RestRequest req = new RestRequest();
        req.requestUri = '/services/apexrest/invoice-callback';
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf('{"salesforce_record_id":"001000000000001AAA","data":{"client_name":"A","invoice_amount":10,"product_name":"P"}}');

        RestContext.request = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        InvoiceCallbackAPI.receiveResult();
        Test.stopTest();

        System.assertEquals(401, RestContext.response.statusCode);
        System.assert(RestContext.response.responseBody.toString().contains('unauthorized'));
    }

    @IsTest
    static void testInvoiceCallbackAcceptsValidToken() {
        setCallbackToken(TEST_CALLBACK_TOKEN);

        RestRequest req = new RestRequest();
        req.requestUri = '/services/apexrest/invoice-callback';
        req.httpMethod = 'POST';
        req.addHeader('X-Callback-Token', TEST_CALLBACK_TOKEN);
        req.requestBody = Blob.valueOf('{"salesforce_record_id":"001000000000001AAA","data":{"response_text":"The invoice total is 245.75 for Acme Service."}}');

        RestContext.request = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        InvoiceCallbackAPI.receiveResult();
        Test.stopTest();

        String responseBody = RestContext.response.responseBody.toString();
        System.assertEquals(200, RestContext.response.statusCode);
        System.assert(responseBody.contains('received'));
        System.assert(responseBody.contains('response_text'));
        System.assert(responseBody.contains('245.75'));
    }

    private static void setCallbackToken(String token) {
        FileExtractionConfig__c orgDefaults = new FileExtractionConfig__c(
            SetupOwnerId = UserInfo.getOrganizationId(),
            CallbackToken__c = token
        );
        upsert orgDefaults;
    }
}