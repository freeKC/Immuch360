var StatusCode;
(function (StatusCode) {
    StatusCode[StatusCode["Success"] = 0] = "Success";
    StatusCode[StatusCode["Pending"] = 259] = "Pending";
    StatusCode[StatusCode["MoreProcessingRequired"] = 3221225494] = "MoreProcessingRequired";
    StatusCode[StatusCode["AccessDenied"] = 3221225506] = "AccessDenied";
    StatusCode[StatusCode["NoMoreFiles"] = 2147483654] = "NoMoreFiles";
    StatusCode[StatusCode["FileNameNotFound"] = 3221225524] = "FileNameNotFound";
    StatusCode[StatusCode["FilePathNotFound"] = 3221225530] = "FilePathNotFound";
    StatusCode[StatusCode["FileClosed"] = 3221225768] = "FileClosed";
    StatusCode[StatusCode["SharingViolation"] = 3221225539] = "SharingViolation"; // Status code for "Sharing Violation - File is in use by another process"
})(StatusCode || (StatusCode = {}));
export default StatusCode;
//# sourceMappingURL=StatusCode.js.map