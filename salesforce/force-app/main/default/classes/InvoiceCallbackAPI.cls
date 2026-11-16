@RestResource(urlMapping='/invoice-callback')
global with sharing class InvoiceCallbackAPI {

    private static final String TOKEN_HEADER = 'X-Callback-Token';

    @HttpPost
    global static void receiveResult() {

        RestRequest req = RestContext.request;
        RestResponse res = RestContext.response;

        if (res == null) {
            res = new RestResponse();
            RestContext.response = res;
        }

        if (!isAuthorizedRequest(req)) {
            writeJsonResponse(401, new Map<String, Object>{
                'status' => 'unauthorized',
                'message' => 'Invalid callback token'
            });
            return;
        }

        String body = req != null && req.requestBody != null ? req.requestBody.toString() : null;
        if (String.isBlank(body)) {
            writeJsonResponse(400, new Map<String, Object>{
                'status' => 'bad_request',
                'message' => 'Request body is empty'
            });
            return;
        }

        Map<String, Object> payload;
        try {
            payload = (Map<String, Object>) JSON.deserializeUntyped(body);
        } catch (Exception ex) {
            writeJsonResponse(400, new Map<String, Object>{
                'status' => 'bad_request',
                'message' => 'Invalid JSON payload'
            });
            return;
        }

        Id recordId = toId(payload.get('salesforce_record_id'));
        Map<String, Object> data = toMap(payload.get('data'));

        if (recordId == null || data == null) {
            writeJsonResponse(400, new Map<String, Object>{
                'status' => 'bad_request',
                'message' => 'salesforce_record_id or data is missing/invalid'
            });
            return;
        }

        String responseText = toStringValue(data.get('response_text'));
        String clientName = toStringValue(data.get('client_name'));
        Decimal invoiceAmount = toDecimal(data.get('invoice_amount'));
        String productName = toStringValue(data.get('product_name'));

        System.debug('Callback received for record: ' + recordId);
        System.debug('Response Text: ' + responseText);
        System.debug('Client Name: ' + clientName);
        System.debug('Invoice Amount: ' + invoiceAmount);
        System.debug('Product Name: ' + productName);

        writeJsonResponse(200, new Map<String, Object>{
            'status' => 'received',
            'salesforce_record_id' => recordId,
            'response_text' => responseText,
            'client_name' => clientName,
            'invoice_amount' => invoiceAmount,
            'product_name' => productName
        });
    }

    private static Boolean isAuthorizedRequest(RestRequest req) {
        if (req == null) {
            return false;
        }
        String configuredToken = getConfiguredCallbackToken();
        if (String.isBlank(configuredToken)) {
            return false;
        }
        String inboundToken = req.headers != null ? req.headers.get(TOKEN_HEADER) : null;
        return !String.isBlank(inboundToken) && inboundToken == configuredToken;
    }

    @TestVisible
    private static String getConfiguredCallbackToken() {
        FileExtractionConfig__c orgDefaults = FileExtractionConfig__c.getOrgDefaults();
        return orgDefaults == null ? null : orgDefaults.CallbackToken__c;
    }

    private static void writeJsonResponse(Integer statusCode, Map<String, Object> payload) {
        RestContext.response.statusCode = statusCode;
        RestContext.response.addHeader('Content-Type', 'application/json');
        RestContext.response.responseBody = Blob.valueOf(JSON.serialize(payload));
    }

    private static Id toId(Object value) {
        if (value == null) {
            return null;
        }
        try {
            return (Id) String.valueOf(value);
        } catch (Exception ex) {
            return null;
        }
    }

    private static Map<String, Object> toMap(Object value) {
        if (value instanceof Map<String, Object>) {
            return (Map<String, Object>) value;
        }
        return null;
    }

    private static String toStringValue(Object value) {
        return value == null ? null : String.valueOf(value);
    }

    private static Decimal toDecimal(Object value) {
        if (value == null) {
            return null;
        }
        if (value instanceof Decimal) {
            return (Decimal) value;
        }
        try {
            return Decimal.valueOf(String.valueOf(value));
        } catch (Exception ex) {
            return null;
        }
    }
}