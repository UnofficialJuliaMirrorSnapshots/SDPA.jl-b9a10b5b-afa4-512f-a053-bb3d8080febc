using BinaryProvider # requires BinaryProvider 0.5.3 or later
using CxxWrap

# Parse some basic command-line arguments
const verbose = "--verbose" in ARGS
const prefix = Prefix(get([a for a in ARGS if a != "--verbose"], 1, joinpath(@__DIR__, "usr")))
products = [
    ExecutableProduct(prefix, "sdpa", :sdpa),
    LibraryProduct(prefix, ["libsdpa"], :libsdpa),
    LibraryProduct(prefix, ["libsdpawrap"], :libsdpawrap),
]

# Download binaries from hosted location
bin_prefix = "https://github.com/JuliaOpt/SDPABuilder/releases/download/v7.3.8-1-static"

# Listing of files generated by BinaryBuilder:
download_info = Dict(
    MacOS(:x86_64, compiler_abi=CompilerABI(:gcc7)) => ("$bin_prefix/SDPABuilder.v7.3.8.x86_64-apple-darwin14-gcc7.tar.gz", "94f164b9ad58d6a66884f5a4fc60ba79aee60416b4189af9dc7313734a34de33"),
    MacOS(:x86_64, compiler_abi=CompilerABI(:gcc8)) => ("$bin_prefix/SDPABuilder.v7.3.8.x86_64-apple-darwin14-gcc8.tar.gz", "dadb3a994ae92395129a9de70738ed38a5427d1281e5f12d9500afaac1093dc2"),
    Linux(:x86_64, libc=:glibc, compiler_abi=CompilerABI(:gcc7, :cxx11)) => ("$bin_prefix/SDPABuilder.v7.3.8.x86_64-linux-gnu-gcc7-cxx11.tar.gz", "52afa44d1b85b2bab129e0c925c50cb1b7c734a3fd0a787c0b229647750821e9"),
    Linux(:x86_64, libc=:glibc, compiler_abi=CompilerABI(:gcc8, :cxx11)) => ("$bin_prefix/SDPABuilder.v7.3.8.x86_64-linux-gnu-gcc8-cxx11.tar.gz", "90bf1b48fda853fdb5cbc51c3566bced5133c85c3cee3d900948345a1072a244"),
)
                    
custom_library = false
if haskey(ENV,"JULIA_SDPA_LIBRARY_PATH")
    custom_products = [LibraryProduct(ENV["JULIA_SDPA_LIBRARY_PATH"],product.libnames,product.variable_name) for product in products]
    if all(satisfied(p; verbose=verbose) for p in custom_products)
        products = custom_products
        custom_library = true
    else
        error("Could not install custom libraries from $(ENV["JULIA_SDPA_LIBRARY_PATH"]).\nTo fall back to BinaryProvider call delete!(ENV,\"JULIA_SDPA_LIBRARY_PATH\") and run build again.")
    end
end

if !custom_library
    # Install unsatisfied or updated dependencies:
    unsatisfied = any(!satisfied(p; verbose=verbose) for p in products)

    dl_info = choose_download(download_info, platform_key_abi())
    if dl_info === nothing && unsatisfied
        # If we don't have a compatible .tar.gz to download, complain.
        # Alternatively, you could attempt to install from a separate provider,
        # build from source or something even more ambitious here.
        error("Your platform (\"$(Sys.MACHINE)\", parsed as \"$(triplet(platform_key_abi()))\") is not supported by this package!")
    end

    # If we have a download, and we are unsatisfied (or the version we're
    # trying to install is not itself installed) then load it up!
    if unsatisfied || !isinstalled(dl_info...; prefix=prefix)
        # Download and install binaries
        # no dynamic dependencies until Pkg3 support for binaries
        # for dependency in reverse(dependencies)          # We do not check for already installed dependencies
        #    download(dependency,basename(dependency))
        #    evalfile(basename(dependency))
        # end
        install(dl_info...; prefix=prefix, force=true, verbose=verbose)
    end
 end
                    
# Write out a deps.jl file that will contain mappings for our products
write_deps_file(joinpath(@__DIR__, "deps.jl"), products, verbose=verbose)