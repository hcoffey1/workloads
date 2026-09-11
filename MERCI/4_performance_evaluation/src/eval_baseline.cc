#include "baseline_options.h"
#include "evaluator.h"
#include "utils.h"

int run_baseline(int argc, const char *argv[]) {
    BaselineOptions options(argc, argv);
    const char *home = getenv("HOME");
    if (!home)
        throw std::runtime_error("HOME must locate the MERCI dataset tree");
    /* static file I/O variables */
    string homeDir = home; // home directory
    string merciDir = homeDir + "/MERCI/data/";                  // MERCI directory (located in $HOME/MERCI)
    string datasetDir = merciDir + "4_filtered";            // input dataset directory

    /*file I/O variables */
    string datasetName = options.dataset;
    string testFileName;
    ifstream testFile;

    /* counter variables */
    int num_features = 0;                   // total number of features (train + test)
    size_t core_count = options.cores;
    int repeat = options.repeats;

    /* helper variables */
    char read_sharp;                    //to read #

    /////////////////////////////////////////////////////////////////////////////  
    cout << "Eval Phase 0: Reading Command Line Arguments..." << endl << endl;
    /////////////////////////////////////////////////////////////////////////////

    cout << "=================== EVAL INFO ==================" << endl;
    cout << "Embedding Dimension                   : " << EMBEDDING_DIM << endl;   
    cout << "Number of Cores Supported by Hardware : " << thread::hardware_concurrency() << endl;
    cout << "Number of Cores                       : " << core_count << endl;
    cout << "Debug                                 : " << DEBUG << endl;
    cout << "===============================================" << endl << endl;    

    ///////////////////////////////////////////////////////////////////////////// 
    cout << "Eval Phase 1: Retrieving Test Queries..." << endl << endl;
    ///////////////////////////////////////////////////////////////////////////// 

    //Step 1: Open test.dat file
    testFileName = datasetDir + "/"+ datasetName + "/" + datasetName + "_test_filtered.txt";
    cout << "testFilename : " << testFileName << endl;
    testFile.open(testFileName, ifstream::in);
    if (testFile.fail()) {
        cout << "FILE ERROR: Could not open test.dat file" << endl;
        return -1;
    }

    //Step 2: Read meta data
    testFile >> read_sharp;
    testFile >> num_features;
    if (!testFile || read_sharp != '#' || num_features <= 0)
        throw std::runtime_error("invalid feature-count header");

    cout << "============= META INFO =============" << endl;
    cout << "# of Features (train + test)    : " << num_features << endl;
    cout << "=====================================" << endl << endl;    

    //Step 3: Read and store query(test) transactions
    QueryData qd(testFile, true, options.seeded ? &options.seed : nullptr);
    validate_queries(qd, num_features);
    testFile.close(); //close file

    vector<thread> t;
    t.resize(core_count);
    qd.partition(core_count);
    cout << endl;

    ///////////////////////////////////////////////////////////////////////////// 
    cout << "Eval Phase 2: Building Embedding Table..." << endl << endl;
    ///////////////////////////////////////////////////////////////////////////// 
    Baseline baseline(num_features, core_count);
    if (options.mapped()) {
        baseline.embedding_table.use_mapping();
        baseline.qres.use_mapping();
        eval_event("prepare_begin", 0, steady_clock::now());
    }
    baseline.build_embedding_table(num_features);
    if (options.mapped()) {
        baseline.init(qd.query.size());
        eval_event("registration_begin", 0, steady_clock::now());
        if (options.application) {
            baseline.embedding_table.register_with(options.registration, 0,
                                                   options.regions[0]);
            baseline.qres.register_with(options.registration, 1,
                                        options.regions[1]);
        }
        baseline_manifest(options, baseline, qd, testFileName);
        eval_event("regions_ready", 0, steady_clock::now());
    }

    ///////////////////////////////////////////////////////////////////////////// 
    cout << "Eval Phase 3: Running Baseline..." << endl << endl;
    /////////////////////////////////////////////////////////////////////////////
    EvalControl control;
    control.warmups = options.warmups;
    control.trace = options.mapped();
    if (options.verify)
        control.verify = [&]() { verify_baseline(baseline, qd); };
    eval<Baseline>(baseline, qd, core_count, t, repeat, "Baseline", &control);

#if DEBUG
    double rsum = 0.0f;
    size_t qlen = qd.query.size();
    for(size_t i=0; i < qlen; i++) {
        size_t curqlen = qd.query[i].size();
        for(size_t j=0; j< curqlen; j++) {
            for(size_t l=0; l < EMBEDDING_DIM; l++) {
                rsum += baseline.embedding_table[qd.query[i][j]][l];
            }
        }
    }
    cout << "Correct Value : " << rsum << "\n";
    #endif
    return 0;
}

int main(int argc, const char *argv[]) {
    if (argc == 2 && std::string(argv[1]) == "--help") {
        std::cout
            << "Usage: eval_baseline -d DATASET [-c THREADS] [-r REPEATS]\n"
            << "  --app-regions --app-region embedding:POLICY:BYTES "
               "--app-region output:POLICY:BYTES\n"
            << "  --region-layout-only   aligned buffers without registration\n"
            << "  --shuffle-seed UINT32  defaults to 1 in either region mode\n"
            << "  --warmups N            excluded trials (default 0)\n"
            << "  --verify               serial check after each trial; "
               "diagnostic runs only\n";
        return 0;
    }
    try {
        return run_baseline(argc, argv);
    } catch (const std::exception &e) {
        std::cerr << "MERCI ERROR: " << e.what() << std::endl;
        return 1;
    }
}
