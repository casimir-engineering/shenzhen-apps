#import "SPDFMarkdownLexers.h"

// Grammar instances for the scripting and query languages that reuse the
// generic parameterized scanner with hash/dash/percent comment styles.

static NSDictionary<NSString*, SPDFMarkdownLexerGrammar*>* SPDFScriptingGrammars(void) {
    static NSDictionary<NSString*, SPDFMarkdownLexerGrammar*>* grammars;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary* map = [NSMutableDictionary dictionary];

        SPDFMarkdownLexerGrammar* ruby = [SPDFMarkdownLexerGrammar grammarWithKeywords:
            @"alias and attr_accessor attr_reader attr_writer begin break case class def do else "
            @"elsif end ensure extend false for if in include lambda module new next nil not or "
            @"private protected public puts raise redo require require_relative rescue retry "
            @"return self super then true undef unless until when while yield"];
        ruby.lineComment = @"#";
        ruby.variableSigils = @"@$";  // instance and global variables
        map[@"ruby"] = ruby;

        SPDFMarkdownLexerGrammar* php = [SPDFMarkdownLexerGrammar grammarWithKeywords:
            @"abstract and array as bool break callable case catch class clone const continue "
            @"declare default do echo else elseif empty enum extends false final finally float fn "
            @"for foreach function global goto if implements include include_once instanceof "
            @"insteadof int interface isset list match mixed namespace never new null or print "
            @"private protected public readonly require require_once return static string switch "
            @"this throw trait true try unset use var void while xor yield"];
        php.lineComment = @"//";
        php.alternateLineComment = @"#";
        php.blockCommentOpen = @"/*";
        php.blockCommentClose = @"*/";
        php.variableSigils = @"$";
        map[@"php"] = php;

        SPDFMarkdownLexerGrammar* shell = [SPDFMarkdownLexerGrammar grammarWithKeywords:
            @"alias break case cd continue coproc declare do done echo elif else esac eval exec "
            @"exit export false fi for function if in local printf read readonly return select "
            @"set shift source test then time trap true typeset unalias unset until wait while"];
        shell.lineComment = @"#";
        shell.quoteCharacters = @"\"'`";
        shell.variableSigils = @"$";
        map[@"shell"] = shell;

        SPDFMarkdownLexerGrammar* perl = [SPDFMarkdownLexerGrammar grammarWithKeywords:
            @"and bless chomp chop cmp defined delete die do each else elsif eq exists for foreach "
            @"ge goto grep gt if index join keys last lc le length local lt map my ne next no not "
            @"or our package pop print printf push redo ref require return reverse say scalar "
            @"shift sort splice split sub substr uc undef unless unshift until use values "
            @"wantarray warn while"];
        perl.lineComment = @"#";
        perl.variableSigils = @"$@%";
        map[@"perl"] = perl;

        SPDFMarkdownLexerGrammar* lua = [SPDFMarkdownLexerGrammar grammarWithKeywords:
            @"and break do else elseif end error false for function goto if in ipairs local nil "
            @"not or pairs pcall print repeat require return self then tonumber tostring true "
            @"type until while"];
        lua.blockCommentOpen = @"--[[";  // checked before the line comment rule
        lua.blockCommentClose = @"]]";
        lua.lineComment = @"--";
        map[@"lua"] = lua;

        SPDFMarkdownLexerGrammar* r = [SPDFMarkdownLexerGrammar grammarWithKeywords:
            @"break else FALSE for function if in Inf library NA NA_character_ NA_integer_ "
            @"NA_real_ NaN next NULL repeat require return TRUE while"];
        r.lineComment = @"#";
        map[@"r"] = r;

        SPDFMarkdownLexerGrammar* haskell = [SPDFMarkdownLexerGrammar grammarWithKeywords:
            @"as case class data default deriving do else family forall foreign hiding if import "
            @"in infix infixl infixr instance let mdo module newtype of pattern qualified role "
            @"then type where"];
        haskell.blockCommentOpen = @"{-";
        haskell.blockCommentClose = @"-}";
        haskell.lineComment = @"--";
        haskell.quoteCharacters = @"\"";  // lone quotes are character literals and primes
        map[@"haskell"] = haskell;

        SPDFMarkdownLexerGrammar* sql = [SPDFMarkdownLexerGrammar grammarWithKeywords:
            @"add all alter and as asc begin between bigint boolean by case char check column "
            @"commit constraint create cross database date decimal default delete desc distinct "
            @"double drop else end except exists foreign from full grant group having if in index "
            @"inner insert int integer intersect into is join key left like limit not null "
            @"numeric offset on or order outer primary recursive references replace returning "
            @"revoke right rollback select serial set smallint table text then timestamp "
            @"transaction truncate union unique update values varchar view when where with"];
        sql.blockCommentOpen = @"/*";
        sql.blockCommentClose = @"*/";
        sql.lineComment = @"--";
        sql.quoteCharacters = @"\"'`";
        sql.caseInsensitiveKeywords = YES;
        map[@"sql"] = sql;

        grammars = [map copy];
    });
    return grammars;
}

NSArray<SPDFMarkdownSyntaxToken*>* SPDFMarkdownScanScripting(
    NSString* identifier, NSString* code, SPDFMarkdownCancellationToken* cancellationToken) {
    SPDFMarkdownLexerGrammar* grammar = SPDFScriptingGrammars()[identifier];
    return grammar ? SPDFMarkdownScanWithGrammar(grammar, code, cancellationToken) : nil;
}
