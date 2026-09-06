namespace BG3Neuro.Core.State;

public sealed class ValidationResult
{
    public bool Success { get; init; }
    public ErrorCode ErrorCode { get; init; }
    public string? ErrorDetail { get; init; }

    public static ValidationResult Ok() => new() { Success = true };

    public static ValidationResult Fail(ErrorCode code, string detail) =>
        new() { Success = false, ErrorCode = code, ErrorDetail = detail };
}
