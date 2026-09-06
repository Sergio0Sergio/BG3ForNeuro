using BG3Neuro.Core.State;
using Xunit;

namespace BG3Neuro.Core.Tests.State;

public class ErrorMapperTests
{
    [Fact]
    public void DefaultMessages_AllCodes_AreNonEmptyAndActionable()
    {
        foreach (var code in ErrorMapper.AllCodes)
        {
            var message = ErrorMapper.DefaultMessage(code);

            Assert.False(string.IsNullOrWhiteSpace(message), $"Код {code} не имеет сообщения по умолчанию");
            Assert.Contains(".", message);
        }
    }

    [Fact]
    public void ToMessage_WithDetail_UsesDetail()
    {
        Assert.Equal("Заклинание 'Wish' недоступно. Известные: Fireball",
            ErrorMapper.ToMessage(ErrorCode.NoSpell, "Заклинание 'Wish' недоступно. Известные: Fireball"));
    }

    [Fact]
    public void ToMessage_WithoutDetail_UsesActionableDefault()
    {
        Assert.Equal(ErrorMapper.DefaultMessage(ErrorCode.TargetMissing),
            ErrorMapper.ToMessage(ErrorCode.TargetMissing, null));
    }

    [Fact]
    public void Dictionary_CoversAllSpecCodes_FromSection65()
    {
        // §6.5: полный перечень кодов — target_missing, not_in_combat, no_spell, no_camp,
        // not_supported, target_not_in_range, invalid_parameters, wrong_phase, dialogue_closed,
        // action_failed, mod_unavailable.
        var expected = new[]
        {
            ErrorCode.TargetMissing,
            ErrorCode.NotInCombat,
            ErrorCode.NoSpell,
            ErrorCode.NoCamp,
            ErrorCode.NotSupported,
            ErrorCode.TargetNotInRange,
            ErrorCode.InvalidParameters,
            ErrorCode.WrongPhase,
            ErrorCode.DialogueClosed,
            ErrorCode.ActionFailed,
            ErrorCode.ModUnavailable,
        };

        Assert.Equal(expected.OrderBy(c => c), ErrorMapper.AllCodes.OrderBy(c => c));
    }

    [Fact]
    public void ValidationCodes_AreChannelA()
    {
        var validationCodes = new[]
        {
            ErrorCode.TargetMissing,
            ErrorCode.NotInCombat,
            ErrorCode.NoSpell,
            ErrorCode.NoCamp,
            ErrorCode.NotSupported,
            ErrorCode.TargetNotInRange,
            ErrorCode.InvalidParameters,
            ErrorCode.WrongPhase,
            ErrorCode.DialogueClosed,
            ErrorCode.ModUnavailable,
        };

        foreach (var code in validationCodes)
        {
            Assert.True(ErrorMapper.IsValidationResult(code), $"{code} должен доставляться Каналом A (action/result)");
        }
    }

    [Fact]
    public void ExecutionFailures_AreChannelB_NotValidationResults()
    {
        Assert.Equal(ErrorMapper.Channel.B, ErrorMapper.ToChannel(ErrorCode.ActionFailed));
        Assert.False(ErrorMapper.IsValidationResult(ErrorCode.ActionFailed),
            "action_failed — провал исполнения, никогда не выдаётся валидацией (Канал B)");
    }

    [Fact]
    public void Router_NeverEmitsChannelB_AsValidationResult()
    {
        // Инвариант: ни один валидационный путь не должен вернуть Канал B код.
        var routerEmittable = new[]
        {
            ErrorCode.ModUnavailable,
            ErrorCode.InvalidParameters,
            ErrorCode.NotInCombat,
            ErrorCode.WrongPhase,
            ErrorCode.TargetMissing,
            ErrorCode.NoSpell,
            ErrorCode.TargetNotInRange,
            ErrorCode.NotSupported,
        };

        foreach (var code in routerEmittable)
        {
            Assert.True(ErrorMapper.IsValidationResult(code), $"Router может вернуть {code}, значит это код Канала A");
        }
    }
}