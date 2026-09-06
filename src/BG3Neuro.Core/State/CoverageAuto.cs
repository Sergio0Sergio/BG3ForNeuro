namespace BG3Neuro.Core.State;

public sealed record AoECoverage(double CenterX, double CenterY, IReadOnlyList<string> Covered);

public static class CoverageAuto
{
    private const double Eps = 1e-6;

    /// <summary>Единый code path для range/AoE-вычислений (spec §1.3, §3.3): StateSerializer и ActionRouter.
    /// Работает в 2D-координатах поля боя (метры); сущности без позиции исключаются.</summary>
    public static IReadOnlyList<string> TargetsInRange(Combatant caster, IEnumerable<Combatant> candidates, double range)
    {
        var result = new List<string>();
        foreach (var candidate in candidates)
        {
            if (HasPosition(caster) && HasPosition(candidate) &&
                Distance(caster, candidate) <= range + Eps)
            {
                result.Add(candidate.Alias);
            }
        }

        return result;
    }

    public static bool IsInRange(Combatant a, Combatant b, double range) =>
        HasPosition(a) && HasPosition(b) && Distance(a, b) <= range + Eps;

    /// <summary>Оптимальное центрирование AoE: кандидаты центра — позиции целей + центроид всех целей.
    /// Выбирается центр с максимумом накрытых целей (детерминированно, при равенстве — первый).</summary>
    public static AoECoverage BestAoECenter(Combatant caster, IReadOnlyList<Combatant> candidates, double range, double aoe)
    {
        var positioned = candidates.Where(HasPosition).ToList();
        var empty = new AoECoverage(0, 0, Array.Empty<string>());
        if (!HasPosition(caster) || positioned.Count == 0 || aoe <= 0)
        {
            return empty;
        }

        var centers = new List<(double X, double Y)>();
        foreach (var p in positioned)
        {
            centers.Add((p.PositionX!.Value, p.PositionY!.Value));
        }

        var centroidX = positioned.Average(p => p.PositionX!.Value);
        var centroidY = positioned.Average(p => p.PositionY!.Value);
        centers.Add((centroidX, centroidY));

        double bestScore = -1;
        var best = empty;
        foreach (var (cx, cy) in centers)
        {
            // центр обязан быть на дистанции управления кастера
            if (Math.Sqrt(Sqr(cx - caster.PositionX!.Value) + Sqr(cy - caster.PositionY!.Value)) > range + Eps)
            {
                continue;
            }

            var covered = positioned
                .Where(p => Math.Sqrt(Sqr(p.PositionX!.Value - cx) + Sqr(p.PositionY!.Value - cy)) <= aoe + Eps)
                .Select(p => p.Alias)
                .OrderBy(a => a, StringComparer.Ordinal)
                .ToList();
            if (covered.Count > bestScore)
            {
                bestScore = covered.Count;
                best = new AoECoverage(cx, cy, covered);
            }
        }

        return best;
    }

    private static bool HasPosition(Combatant c) => c.PositionX.HasValue && c.PositionY.HasValue;

    private static double Distance(Combatant a, Combatant b) =>
        Math.Sqrt(Sqr(a.PositionX!.Value - b.PositionX!.Value) + Sqr(a.PositionY!.Value - b.PositionY!.Value));

    private static double Sqr(double v) => v * v;
}