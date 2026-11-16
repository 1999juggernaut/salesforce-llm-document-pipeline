public with sharing class ContentVersionTriggerHandler {

    @TestVisible
    private static final Integer MAX_QUEUEABLE_PER_TRANSACTION = 45;

    @TestVisible
    private static final Integer MAX_CONTENT_SIZE_BYTES = 4500000;

    private static final Set<String> SUPPORTED_TYPES = new Set<String>{'PDF', 'DOCX', 'XLSX', 'WORD_X', 'EXCEL_X', 'WORD', 'EXCEL', 'DOC', 'XLS'};

    public static void handleAfterInsert(List<ContentVersion> newRecords) {
        if (newRecords == null || newRecords.isEmpty()) {
            return;
        }

        Integer enqueuedCount = 0;

        for (ContentVersion cv : newRecords) {
            if (enqueuedCount >= MAX_QUEUEABLE_PER_TRANSACTION) {
                System.debug('Queueable enqueue limit reached. Remaining files are skipped.');
                break;
            }

            if (cv == null || !cv.IsLatest) {
                continue;
            }

            if (!isSupportedFileType(cv.FileType)) {
                System.debug('Skipping unsupported file type for ContentVersion ' + cv.Id + ': ' + cv.FileType);
                continue;
            }

            if (cv.ContentSize != null && cv.ContentSize > MAX_CONTENT_SIZE_BYTES) {
                System.debug('Skipping oversized file for ContentVersion ' + cv.Id + ': ' + cv.ContentSize + ' bytes');
                continue;
            }

            String extractionQuery = buildExtractionQuery(cv.Title, cv.FileType);
            System.enqueueJob(new FileExtractionCallout(cv.Id, extractionQuery));
            enqueuedCount++;
        }
    }

    private static Boolean isSupportedFileType(String fileType) {
        return !String.isBlank(fileType) && SUPPORTED_TYPES.contains(fileType.toUpperCase());
    }

    @TestVisible
    private static String buildExtractionQuery(String fileName, String fileType) {
        String normalizedType = String.isBlank(fileType) ? '' : fileType.toUpperCase();

        if (normalizedType == 'PDF') {
            return 'PDF: Extract key business entities (names, organizations), dates, monetary amounts, identifiers, and provide a concise summary. If tables exist, summarize table headers and important aggregates.';
        }

        if (
            normalizedType == 'DOCX'
            || normalizedType == 'WORD_X'
            || normalizedType == 'WORD'
            || normalizedType == 'DOC'
        ) {
            return 'DOCX: Extract named entities, obligations, dates, amounts, and produce a short structured summary with any action items or clauses of interest.';
        }

        if (
            normalizedType == 'XLSX'
            || normalizedType == 'EXCEL_X'
            || normalizedType == 'EXCEL'
            || normalizedType == 'XLS'
        ) {
            return 'XLSX: Extract all table/worksheet names, column headers, key numeric totals, date ranges, and summarize notable rows or aggregates in a structured format.';
        }

        return 'File type not supported for automated extraction.';
    }
}