@testset "SubproblemCallback creation" begin
    f(arg::Any) = "Throws error"
    SubproblemCallback(f)
end