/**
 * SIMPLIFIED SALESFORCE APEX CODE
 * For testing with System.debug() only (no custom fields needed)
 * 
 * Just logs extracted data to Debug Logs in Salesforce
 * Deploy and test - no field creation required!
 */

/**
 * ============================================
 * MAIN CALLOUT: File Extraction Queueable Job
 * ============================================
 */
public class FileExtractionCallout implements Queueable, Database.AllowsCallouts {

    @TestVisible
    private static final Integer MAX_CONTENT_SIZE_BYTES = 4500000;

    @TestVisible
    private static final String EXTRACTION_ENDPOINT = 'callout:DocExtractionService/extract';

    private static final Set<String> SUPPORTED_TYPES = new Set<String>{'PDF', 'DOCX', 'XLSX', 'WORD_X', 'EXCEL_X', 'WORD', 'EXCEL', 'DOC', 'XLS'};
    private static final String DEFAULT_QUERY =
        'Extract important business entities, dates, amounts, identifiers, and key terms relevant to user questions.';
    private static final String CALLBACK_PATH = '/services/apexrest/invoice-callback';

    private Id contentVersionId;
    private String userQuery;

    /**
     * Constructor
     * @param cvId ContentVersion ID to extract from
     * @param query User query for extraction (e.g., "Extract invoice number and amount")
     */
    public FileExtractionCallout(Id cvId, String query) {
        this.contentVersionId = cvId;
        this.userQuery = query;
    }

    public void execute(QueueableContext context) {
        try {
            System.debug('========== FILE EXTRACTION STARTED ==========');
            System.debug('ContentVersion ID: ' + contentVersionId);
            System.debug('User Query: ' + userQuery);

            // Get the file from ContentVersion
            ContentVersion cv = [
                SELECT Id, Title, VersionData, FileType, ContentSize
                FROM ContentVersion
                WHERE Id = :contentVersionId
                LIMIT 1
            ];

            System.debug('File Name: ' + cv.Title);
            System.debug('File Type: ' + cv.FileType);
            System.debug('File Size: ' + cv.VersionData.size() + ' bytes');

            // Validate file type
            if (!isSupportedFileType(cv.FileType)) {
                System.debug('ERROR: Unsupported file type: ' + cv.FileType);
                System.debug('Supported types: PDF, DOCX, XLSX');
                return;
            }

            if (cv.ContentSize != null && cv.ContentSize > MAX_CONTENT_SIZE_BYTES) {
                System.debug('ERROR: File is too large for extraction. Size=' + cv.ContentSize);
                return;
            }

            if (cv.VersionData == null || cv.VersionData.size() == 0) {
                System.debug('ERROR: File body is empty.');
                return;
            }

            System.debug('File type supported');

            // Convert file to Base64
            String base64File = EncodingUtil.base64Encode(cv.VersionData);
            System.debug('Base64 length: ' + base64File.length() + ' chars');

            String effectiveQuery = String.isBlank(this.userQuery) ? DEFAULT_QUERY : this.userQuery;
            String callbackToken = getConfiguredCallbackToken();
            if (String.isBlank(callbackToken)) {
                System.debug('WARN: Callback token is not configured. Python callback authorization will fail.');
            }

            // Build payload
            Map<String, Object> payload = new Map<String, Object>{
                'file_name' => cv.Title + '.' + getFileExtension(cv.FileType),
                'file_base64' => base64File,
                'user_query' => effectiveQuery,
                'context' => 'salesforce-file-upload',
                'salesforce_record_id' => cv.Id,
                'callback_url' => URL.getOrgDomainUrl().toExternalForm() + CALLBACK_PATH,
                'callback_token' => callbackToken
            };

            System.debug('Sending request to Python API...');
            System.debug('Payload keys: ' + payload.keySet());

            // Send to FastAPI
            HttpResponse response = sendExtractionRequest(JSON.serialize(payload));

            // Handle response
            handleExtractionResponse(response);

        } catch (Exception e) {
            System.debug('EXCEPTION: ' + e.getMessage());
            System.debug('Stack Trace: ' + e.getStackTraceString());
        }

        System.debug('========== FILE EXTRACTION ENDED ==========');
    }

    /**
     * Send extraction request to Python FastAPI
     */
    private HttpResponse sendExtractionRequest(String payload) {
        Http http = new Http();
        HttpRequest req = new HttpRequest();

        req.setEndpoint(EXTRACTION_ENDPOINT);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setTimeout(60000);

        req.setBody(payload);

        System.debug('Calling endpoint: ' + EXTRACTION_ENDPOINT);

        return http.send(req);
    }

    /**
     * Process the extraction response and log everything
     */
    private void handleExtractionResponse(HttpResponse res) {
        Integer statusCode = res.getStatusCode();
        String responseBody = res.getBody();
        if (responseBody == null) {
            responseBody = '';
        }

        System.debug('Response Status Code: ' + statusCode);
        System.debug('Response Body Length: ' + responseBody.length() + ' chars');
        System.debug('Response Body: ');
        System.debug(responseBody);

        if (statusCode == 200) {
            try {
                // Parse JSON response
                Map<String, Object> responseData = 
                    (Map<String, Object>) JSON.deserializeUntyped(responseBody);

                System.debug('Response parsed successfully');
                System.debug('Response keys: ' + responseData.keySet());

                // Extract all fields
                Boolean success = toBoolean(responseData.get('success'));
                System.debug('Success Flag: ' + success);

                if (success) {
                    System.debug('');
                    System.debug('==========================================');
                    System.debug('EXTRACTION SUCCESSFUL');
                    System.debug('==========================================');

                    String fileName = (String) responseData.get('file_name');
                    String userQuery = (String) responseData.get('user_query');
                    String extractedText = (String) responseData.get('extracted_text');
                    Integer charCount = toInteger(responseData.get('character_count'));
                    Boolean withinLimit = toBoolean(responseData.get('within_salesforce_limit'));

                    System.debug('File Name: ' + fileName);
                    System.debug('User Query: ' + userQuery);
                    System.debug('Character Count: ' + charCount);
                    System.debug('Within Salesforce Limit (131,072): ' + withinLimit);
                    System.debug('');
                    System.debug('EXTRACTED TEXT:');
                    System.debug('-----------------------------------------');
                    System.debug(extractedText);
                    System.debug('-----------------------------------------');

                } else {
                    System.debug('');
                    System.debug('==========================================');
                    System.debug('EXTRACTION FAILED');
                    System.debug('==========================================');

                    String error = (String) responseData.get('error');
                    System.debug('Error Message: ' + error);
                    System.debug('');
                }

            } catch (Exception e) {
                System.debug('Error parsing JSON response: ' + e.getMessage());
                System.debug('Raw response: ' + responseBody);
            }
        } else {
            System.debug('');
            System.debug('==========================================');
            System.debug('API ERROR - Status: ' + statusCode);
            System.debug('==========================================');
            System.debug('Response: ' + responseBody);
            System.debug('');
        }
    }

    private static Boolean isSupportedFileType(String fileType) {
        return !String.isBlank(fileType) && SUPPORTED_TYPES.contains(fileType.toUpperCase());
    }

    @TestVisible
    private static String getFileExtension(String fileType) {
        String normalizedType = String.isBlank(fileType) ? '' : fileType.toUpperCase();

        if (normalizedType == 'PDF') {
            return 'pdf';
        }

        if (
            normalizedType == 'DOCX'
            || normalizedType == 'WORD_X'
            || normalizedType == 'WORD'
            || normalizedType == 'DOC'
        ) {
            return 'docx';
        }

        if (
            normalizedType == 'XLSX'
            || normalizedType == 'EXCEL_X'
            || normalizedType == 'EXCEL'
            || normalizedType == 'XLS'
        ) {
            return 'xlsx';
        }

        return normalizedType.toLowerCase();
    }

    private static Boolean toBoolean(Object value) {
        if (value == null) {
            return false;
        }
        if (value instanceof Boolean) {
            return (Boolean) value;
        }
        return 'true'.equalsIgnoreCase(String.valueOf(value));
    }

    private static Integer toInteger(Object value) {
        if (value == null) {
            return null;
        }
        if (value instanceof Integer) {
            return (Integer) value;
        }
        if (value instanceof Long) {
            return Integer.valueOf(String.valueOf(value));
        }
        if (value instanceof Decimal) {
            return ((Decimal) value).intValue();
        }
        String asText = String.valueOf(value);
        if (String.isBlank(asText)) {
            return null;
        }
        return Integer.valueOf(asText);
    }

    private static String getConfiguredCallbackToken() {
        FileExtractionConfig__c orgDefaults = FileExtractionConfig__c.getOrgDefaults();
        return orgDefaults == null ? null : orgDefaults.CallbackToken__c;
    }
}