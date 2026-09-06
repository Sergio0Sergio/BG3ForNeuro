using BG3Neuro.Core.State;
using Xunit;

namespace BG3Neuro.Core.Tests.State;

public class CoverageAutoTests
{
    private static Combatant C(string alias, double x, double y) => new()
    {
        Alias = alias,
        Name = alias,
        PositionX = x,
        PositionY = y,
    };

    [Fact]
    public void TargetsInRange_ReturnsCandidatesWithinRange()
    {
        var caster = C("karlach", 0, 0);
        var inRange = C("goblin_1", 3, 4);    // 5м
        var far = C("goblin_2", 8, 6);        // 10м

        var result = CoverageAuto.TargetsInRange(caster, new[] { inRange, far }, 6);

        Assert.Equal(new[] { "goblin_1" }, result);
    }

    [Fact]
    public void TargetsInRange_NoPositions_ReturnsEmpty()
    {
        var caster = new Combatant { Alias = "karlach", Name = "K", PositionX = 0, PositionY = 0 };
        var noPos = new Combatant { Alias = "goblin_1", Name = "G" };

        Assert.Empty(CoverageAuto.TargetsInRange(caster, new[] { noPos }, 6));
    }

    [Fact]
    public void IsInRange_WithinBoundary_True_JustOutside_False()
    {
        var a = C("a", 0, 0);
        var atEdge = C("b", 6, 0);
        var beyond = C("c", 6.5, 0);

        Assert.True(CoverageAuto.IsInRange(a, atEdge, 6));
        Assert.False(CoverageAuto.IsInRange(a, beyond, 6));
    }

    [Fact]
    public void BestAoECenter_ClustersTargetsAndReportsCoverage()
    {
        var caster = C("karlach", 0, 0);
        var t1 = C("goblin_1", 5, 0);
        var t2 = C("goblin_2", 6, 0);
        var t3 = C("goblin_3", 5.2, 0.3); // близко к t1/t2
        var alone = C("goblin_4", 30, 30); // далеко, вне range

        // AoE 2м вокруг лучшего центра покрывает t1,t2,t3
        var coverage = CoverageAuto.BestAoECenter(caster, new[] { t1, t2, t3, alone }, 10, 2);

        Assert.Equal(3, coverage.Covered.Count);
        Assert.Contains("goblin_1", coverage.Covered);
        Assert.Contains("goblin_2", coverage.Covered);
        Assert.Contains("goblin_3", coverage.Covered);
        Assert.DoesNotContain("goblin_4", coverage.Covered);
    }

    [Fact]
    public void BestAoECenter_NoPositions_ReturnsEmptyCoverage()
    {
        var caster = C("karlach", 0, 0);
        var noPos = new Combatant { Alias = "goblin_1", Name = "G" };

        var coverage = CoverageAuto.BestAoECenter(caster, new[] { noPos }, 10, 2);

        Assert.Empty(coverage.Covered);
    }

    [Fact]
    public void BestAoECenter_TooSmallAoE_CoversNoMoreThanOne()
    {
        var caster = C("karlach", 0, 0);
        var t1 = C("goblin_1", 10, 0);
        var t2 = C("goblin_2", 11.5, 0); // в 1.5м от t1, но AoE 0.1 не накрывает оба

        // Лучший центр накрывает только одну цель (обе на контролируемой дистанции)
        var coverage = CoverageAuto.BestAoECenter(caster, new[] { t1, t2 }, 12, 0.1);

        Assert.True(coverage.Covered.Count <= 1, "AoE 0.1 не должен одновременно покрывать обе цели");
    }
}