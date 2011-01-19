//
//  AutoSuggestManager.m
//  ToolbarSearch
//
//  Created by Brandon George on 9/16/10.
//  Copyright 2010 __MyCompanyName__. All rights reserved.
//

#import "AutoSuggestManager.h"

#define kPhraseTypeHistory 1
#define kPhraseTypeCommon  2
#define kPhraseLimit       1000
#define kDBFilename		   @"verbatim.sql"


@interface AutoSuggestManager (private)

- (void)_setNewLanguage:(NSString *)newLanguage withLanguageVar:(NSString **)languageVar;
- (void)_createTables;
- (NSString *)_getWritableDBPath;
- (void)_createWritableCopyOfDatabaseIfNeeded;
- (void)_closeDatabase;
- (void)_finalizePrecompiledStatements;

@end

@implementation AutoSuggestManager

+ (AutoSuggestManager *)sharedInstance {
	static AutoSuggestManager * instance = nil;
	if (instance == nil) {
		instance = [[AutoSuggestManager alloc] init];
	}
	return instance;
}

- (id)init {
	if (self = [super init]) {
		// connect to database
		[self _createWritableCopyOfDatabaseIfNeeded];
		sqlite3_open([[self _getWritableDBPath] UTF8String], &_db);
		
		//temp
		self.sourceLanguage = @"en";	// TODO - change to source language stored in NSUserDefaults (probably done external to the class)
	}
	return self;
}

- (NSString *)sourceLanguage {
	return _sourceLanguage;
}

- (NSString *)destLanguage {
	return _destLanguage;
}

- (void)setSourceLanguage:(NSString *)newSourceLanguage {
	[self _setNewLanguage:newSourceLanguage withLanguageVar:&_sourceLanguage];
}

- (void)setDestLanguage:(NSString *)newDestLanguage {
	[self _setNewLanguage:newDestLanguage withLanguageVar:&_destLanguage];
}

- (NSDictionary *)getAllPhrases:(NSString *)filterString {
	// query db for all common phrases and history, prioritize history
	NSMutableArray * phrases = [NSMutableArray array];
	NSMutableArray * historyPhraseIds = [NSMutableArray array];
	
	// compile statement if necessary
    if (_getAllPhrasesStatement == nil) {
		NSString * sql = [NSString stringWithFormat:@"SELECT rowid, phrase, type FROM original_phrases_%@ WHERE phrase LIKE ? ORDER BY type ASC, time DESC LIMIT %d", _sourceLanguage, kPhraseLimit];
        if (sqlite3_prepare_v2(_db, [sql UTF8String], -1, &_getAllPhrasesStatement, NULL) != SQLITE_OK) {
			// TODO - preparation error...
        }
    }
	
	// bind the filter string
	NSString * likeParam = ([filterString length] > 0 ? [NSString stringWithFormat:@"%%%@%%", filterString] : @"%");
	sqlite3_bind_text(_getAllPhrasesStatement, 1, [likeParam UTF8String], -1, SQLITE_TRANSIENT);
	
    // execute the query
	while (sqlite3_step(_getAllPhrasesStatement) == SQLITE_ROW) {
		[phrases addObject:[NSString stringWithUTF8String:(char *)sqlite3_column_text(_getAllPhrasesStatement, 1)]];
		int phraseType = sqlite3_column_int(_getAllPhrasesStatement, 2);
		if (phraseType == kPhraseTypeHistory) {
			[historyPhraseIds addObject:[NSNumber numberWithLongLong:sqlite3_column_int64(_getAllPhrasesStatement, 0)]];
		} else {
			[historyPhraseIds addObject:[NSNumber numberWithLongLong:0]];
		}
	}
	sqlite3_reset(_getAllPhrasesStatement);
	
	return [NSDictionary dictionaryWithObjectsAndKeys:phrases, @"phrases", historyPhraseIds, @"historyPhraseIds", nil];
}

- (void)addToHistory:(NSString *)originalText translatedText:(NSString *)translatedText {
    if ([originalText isEqualToString:@""]) {
        return;
    }
    
	// if already exists of type history/common phrase, update timestamp and type to history; otherwise, add to history

	// compile statement if necessary
    if (_checkPhraseStatement == nil) {
		NSString * sql = [NSString stringWithFormat:@"SELECT rowid, type FROM original_phrases_%@ WHERE phrase = ?", _sourceLanguage];
        if (sqlite3_prepare_v2(_db, [sql UTF8String], -1, &_checkPhraseStatement, NULL) != SQLITE_OK) {
			// TODO - add preparation error
        }
    }
	
	// execute the query
	sqlite3_int64 phraseRowId = 0;
	BOOL textAlreadyInHistory = NO;
	sqlite3_bind_text(_checkPhraseStatement, 1, [originalText UTF8String], -1, SQLITE_TRANSIENT);
	if (sqlite3_step(_checkPhraseStatement) == SQLITE_ROW) {
		phraseRowId = sqlite3_column_int64(_checkPhraseStatement, 0);
		
		// mark as history type so that we don't insert into history table down below
		int phraseType = sqlite3_column_int(_checkPhraseStatement, 1);
		if (phraseType == kPhraseTypeHistory) {
			textAlreadyInHistory = YES;
		}

		// compile statement if necessary
		if (_updateToHistoryStatement == nil) {
			NSString * sql = [NSString stringWithFormat:@"UPDATE original_phrases_%@ SET type = %d, time = strftime('%%s','now') WHERE rowid = ?", _sourceLanguage, kPhraseTypeHistory];
			if (sqlite3_prepare_v2(_db, [sql UTF8String], -1, &_updateToHistoryStatement, NULL) != SQLITE_OK) {
				// TODO - add preparation error
			}
		}
		
		sqlite3_bind_int64(_updateToHistoryStatement, 1, phraseRowId);
		sqlite3_step(_updateToHistoryStatement);
		sqlite3_reset(_updateToHistoryStatement);
	} else {
		// compile statement if necessary
		if (_addHistoryStatement == nil) {
			NSString * sql = [NSString stringWithFormat:@"INSERT INTO original_phrases_%@ VALUES (?, %d, strftime('%%s','now'))", _sourceLanguage, kPhraseTypeHistory];
			if (sqlite3_prepare_v2(_db, [sql UTF8String], -1, &_addHistoryStatement, NULL) != SQLITE_OK) {
				// TODO - add preparation error
			}
		}
		
		sqlite3_bind_text(_addHistoryStatement, 1, [originalText UTF8String], -1, SQLITE_TRANSIENT);
		sqlite3_step(_addHistoryStatement);
		phraseRowId = sqlite3_last_insert_rowid(_db);
		sqlite3_reset(_addHistoryStatement);
	}
	
	sqlite3_reset(_checkPhraseStatement);
	
	// add translation to history (if applicable)
	if (phraseRowId != 0 && !textAlreadyInHistory) {
		// compile statement if necessary
		if (_addTranslatedHistoryStatement == nil) {
			NSString * sql = [NSString stringWithFormat:@"INSERT INTO translated_phrases_%@_%@ VALUES (?, ?)", _sourceLanguage, _destLanguage];
			if (sqlite3_prepare_v2(_db, [sql UTF8String], -1, &_addTranslatedHistoryStatement, NULL) != SQLITE_OK) {
				// TODO - add preparation error
			}
		}
		
		sqlite3_bind_int64(_addTranslatedHistoryStatement, 1, phraseRowId);
		sqlite3_bind_text(_addTranslatedHistoryStatement, 2, [translatedText UTF8String], -1, SQLITE_TRANSIENT);
		sqlite3_step(_addTranslatedHistoryStatement);
		sqlite3_reset(_addTranslatedHistoryStatement);
	}
}

- (NSString *)getTranslatedPhrase:(long long)originalPhraseId {
	NSString * translatedPhrase = nil;
	
	// compile statement if necessary
	if (_getTranslatedHistoryStatement == nil) {
		NSString * sql = [NSString stringWithFormat:@"SELECT translation FROM translated_phrases_%@_%@ WHERE originalPhraseId = ?", _sourceLanguage, _destLanguage];
		if (sqlite3_prepare_v2(_db, [sql UTF8String], -1, &_getTranslatedHistoryStatement, NULL) != SQLITE_OK) {
			// TODO - add preparation error
		}		
	}
		
	sqlite3_bind_int64(_getTranslatedHistoryStatement, 1, (sqlite3_int64)originalPhraseId);
	if (sqlite3_step(_getTranslatedHistoryStatement) == SQLITE_ROW) {
		translatedPhrase = [NSString stringWithUTF8String:(char *)sqlite3_column_text(_getTranslatedHistoryStatement, 0)];
	}
	sqlite3_reset(_getTranslatedHistoryStatement);
	
	return translatedPhrase;
}

- (void)clearHistory {
	// compile statement if necessary
	if (_clearHistoryStatement == nil) {
		// TODO - only delete history types or common phrases too?  If only history types, do we restore common phrases that are history types back to common phrase types?
		// TODO - nuke all languages
		// TODO - need to also delete history tables
		NSString * sql = [NSString stringWithFormat:@"DELETE FROM original_phrases_%@", _sourceLanguage];
		if (sqlite3_prepare_v2(_db, [sql UTF8String], -1, &_clearHistoryStatement, NULL) != SQLITE_OK) {
			// TODO - add preparation error
		}
	}
	
	sqlite3_step(_clearHistoryStatement);
	sqlite3_reset(_clearHistoryStatement);	
}

// private methods

- (void)_setNewLanguage:(NSString *)newLanguage withLanguageVar:(NSString **)languageVar {
	// set new language
	if (newLanguage == nil) {
		return;
	} else if (*languageVar == nil) {
		*languageVar = [newLanguage retain];
	} else if ([*languageVar isEqualToString:newLanguage]) {
		return;
	} else {
		[*languageVar release];
		*languageVar = [newLanguage retain];
	}
	
	// precompiled statements are based on both source/dest languages
	[self _finalizePrecompiledStatements];
	
	// create new suggestion/history tables (if applicable)
	[self _createTables];
}

- (void)_createTables {
	// phrase table
	if (_sourceLanguage) {
		NSString * phraseTableSql = [NSString stringWithFormat:@"CREATE TABLE IF NOT EXISTS original_phrases_%@ (phrase varchar(500), type tinyint, time int)", _sourceLanguage];
		sqlite3_exec(_db, [phraseTableSql UTF8String], NULL, NULL, NULL);
	}
	
	// history table
	if (_sourceLanguage && _destLanguage) {
		NSString * historyTableSql = [NSString stringWithFormat:@"CREATE TABLE IF NOT EXISTS translated_phrases_%@_%@ (originalPhraseId int64, translation varchar(1000))", _sourceLanguage, _destLanguage];
		sqlite3_exec(_db, [historyTableSql UTF8String], NULL, NULL, NULL);
	}
}

- (NSString *)_getWritableDBPath {
	NSArray * paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
	NSString * documentsDirectory = [paths objectAtIndex:0];
	return [documentsDirectory stringByAppendingPathComponent:kDBFilename];
}

- (void)_createWritableCopyOfDatabaseIfNeeded {
	// check for existance of a writable db copy
	NSFileManager * fileManager = [NSFileManager defaultManager];
	NSString * writableDBPath = [self _getWritableDBPath];
	if ([fileManager fileExistsAtPath:writableDBPath]) {
		return;
	} else {
		// create a writable db copy (necessary for changing the db contents)
		NSString * bundledDBPath = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:kDBFilename];
		if (![fileManager copyItemAtPath:bundledDBPath toPath:writableDBPath error:nil]) {
			// TODO - add copy error
		}
	}
}

- (void)_closeDatabase {
	[self _finalizePrecompiledStatements];
	sqlite3_close(_db);
}

- (void)_finalizePrecompiledStatements {
	if (_getAllPhrasesStatement) {
        sqlite3_finalize(_getAllPhrasesStatement);
        _getAllPhrasesStatement = nil;
    }

	if (_checkPhraseStatement) {
        sqlite3_finalize(_checkPhraseStatement);
        _checkPhraseStatement = nil;
    }

	if (_addTranslatedHistoryStatement) {
        sqlite3_finalize(_addTranslatedHistoryStatement);
        _addTranslatedHistoryStatement = nil;
    }	
	
	if (_getTranslatedHistoryStatement) {
        sqlite3_finalize(_getTranslatedHistoryStatement);
        _getTranslatedHistoryStatement = nil;
    }	
	
	if (_updateToHistoryStatement) {
        sqlite3_finalize(_updateToHistoryStatement);
        _updateToHistoryStatement = nil;
    }

	if (_addHistoryStatement) {
        sqlite3_finalize(_addHistoryStatement);
        _addHistoryStatement = nil;
    }

	if (_clearHistoryStatement) {
        sqlite3_finalize(_clearHistoryStatement);
        _clearHistoryStatement = nil;
    }	
}

- (void)dealloc {
	[self _closeDatabase];
	[_sourceLanguage release];
	[_destLanguage release];
	[super dealloc];
}

@end
